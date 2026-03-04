# FDv2 Key Type Flow

## Data Pipeline

```mermaid
graph TD
    subgraph "Streaming Protocol Layer"
        A["SSE Stream\n(raw JSON)"] -->|"JSON.parse(symbolize_names: true)"| B["Parsed Hash\nhash keys = SYMBOL\nhash values = STRING\n{key: 'my-flag', version: 1}"]
        B -->|"PutObject.from_h\nkey.to_sym"| C["PutObject / DeleteObject\n@key = SYMBOL\n:my_flag"]
    end

    subgraph "ChangeSet Layer"
        C -->|"add_put / add_delete"| D["Change\n@key = SYMBOL\n:my_flag"]
        D --> E["ChangeSet\nchanges = [Change...]"]
    end

    subgraph "Store Layer"
        E -->|"store.apply(change_set)"| F["changes_to_store_data\nHash keys = SYMBOL\nDELETE value key = .to_s ✅\n{FEATURES => {:my_flag => obj}}"]

        F -->|"memory_store.set_basis /\napply_delta"| G["InMemoryFeatureStoreV2\n@items keys = SYMBOL\n:my_flag"]

        F -->|"decode_collection →\nModel.deserialize"| H["FeatureFlag\n@key = STRING\n'my-flag'\n(extracted from data[:key])"]
    end

    subgraph "Dependency Tracker"
        F -->|"key.to_s ✅"| I["DependencyTracker\nfrom_what = {kind:, key: STRING}\n'my-flag'"]
        H -->|"prereq.key / clause.values"| J["Dependencies\n{kind:, key: STRING}\n'prereq-flag'"]
        I --- J
        I -->|"add_affected_items\nlookup @to hash"| K["affected_items\n{kind:, key: STRING}\n'my-flag', 'prereq-flag'"]
    end

    subgraph "Flag Change Notification"
        K -->|"FlagChange.new(item[:key])"| L["FlagChange\n@key = STRING ✅\n'my-flag'"]
        L -->|"broadcaster"| M["FlagValueChangeAdapter\n.to_s comparison ✅\n.to_s on eval_fn call ✅\n.to_s on emitted key ✅"]
    end

    subgraph "Client API (reads)"
        N["LDClient.variation('my-flag', ...)\nkey = STRING"] -->|"store.get(FEATURES, key)"| O["InMemoryFeatureStoreV2.get\nkey.to_sym for lookup"]
        O --> G
    end

    style I fill:#90EE90
    style K fill:#90EE90
    style J fill:#90EE90
    style L fill:#90EE90
    style M fill:#90EE90
    style F fill:#90EE90
```

## Sequence Diagrams

These show the key type at each handoff point, with `.to_s` conversions marked.

**Legend:** Yellow background = key is a **Symbol**, Blue background = key is a **String**.

### PUT flow (flag received from stream)

```mermaid
sequenceDiagram
    participant SSE as SSE Stream
    participant Parse as JSON Parser
    participant PO as PutObject
    participant CS as ChangeSet
    participant Store as Store
    participant Mem as InMemoryStore
    participant DT as DependencyTracker
    participant BC as Broadcaster
    participant Adapter as FlagValueChangeAdapter

    SSE->>Parse: raw JSON {"key":"my-flag", ...}
    rect rgb(255, 248, 200)
        Note over Parse: JSON.parse(symbolize_names: true)<br/>hash = {key: "my-flag", ...}<br/>hash keys = Symbol, values = String
    end

    Parse->>PO: PutObject.from_h(hash)
    rect rgb(255, 248, 200)
        Note over PO: @key = hash[:key].to_sym<br/>→ :my_flag (SYMBOL)
    end

    PO->>CS: add_put(:my_flag, 1, obj)
    rect rgb(255, 248, 200)
        Note over CS: Change @key = :my_flag (SYMBOL)
    end

    CS->>Store: apply(change_set)
    rect rgb(255, 248, 200)
        Note over Store: changes_to_store_data<br/>hash key = :my_flag (SYMBOL)<br/>value[:key] = "my-flag" (STRING, from obj)
    end

    Store->>Mem: set_basis / apply_delta
    rect rgb(255, 248, 200)
        Note over Mem: @items[:my_flag] = obj<br/>index key = SYMBOL
    end

    Store->>DT: update_dependencies_from(kind, key.to_s, item)
    rect rgb(200, 220, 255)
        Note over DT: from_key = "my-flag" (STRING)<br/>prereq.key = "my-flag" (STRING)<br/>types match for hash lookups
    end

    DT->>Store: affected_items {kind:, key: "my-flag"}
    rect rgb(200, 220, 255)
        Note over Store: item[:key] is already STRING
    end

    Store->>BC: FlagChange.new("my-flag")
    rect rgb(200, 220, 255)
        Note over BC: @key = "my-flag" (STRING)
    end

    BC->>Adapter: update(flag_change)
    rect rgb(200, 220, 255)
        Note over Adapter: flag_change.key.to_s == @flag_key.to_s<br/>tolerates Symbol or String
    end
```

### DELETE flow (flag deleted from stream)

```mermaid
sequenceDiagram
    participant SSE as SSE Stream
    participant Parse as JSON Parser
    participant DO as DeleteObject
    participant CS as ChangeSet
    participant Store as Store
    participant Mem as InMemoryStore
    participant DT as DependencyTracker
    participant BC as Broadcaster

    SSE->>Parse: raw JSON {"key":"my-flag", "version":2}
    rect rgb(255, 248, 200)
        Note over Parse: hash = {key: "my-flag", version: 2}
    end

    Parse->>DO: DeleteObject.from_h(hash)
    rect rgb(255, 248, 200)
        Note over DO: @key = :my_flag (SYMBOL)
    end

    DO->>CS: add_delete(:my_flag, 2)
    rect rgb(255, 248, 200)
        Note over CS: Change @key = :my_flag (SYMBOL)
    end

    CS->>Store: apply(change_set)
    rect rgb(255, 248, 200)
        Note over Store: changes_to_store_data<br/>hash key = :my_flag (SYMBOL)
    end
    rect rgb(200, 220, 255)
        Note over Store: value = {key: change.key.to_s, ...}<br/>→ {key: "my-flag", ...} (.to_s conversion)
    end

    Store->>Mem: apply_delta
    rect rgb(255, 248, 200)
        Note over Mem: @items[:my_flag] = deleted tombstone
    end

    Store->>DT: update_dependencies_from(kind, "my-flag", item)
    rect rgb(200, 220, 255)
        Note over DT: deleted item → clears deps<br/>key = "my-flag" (STRING)
    end

    DT->>Store: affected_items {kind:, key: "my-flag"}
    rect rgb(200, 220, 255)
        Note over Store: key = "my-flag" (STRING)
    end

    Store->>BC: FlagChange.new("my-flag")
    rect rgb(200, 220, 255)
        Note over BC: @key = "my-flag" (STRING)
    end
```

### Dependency propagation (prerequisite change)

```mermaid
sequenceDiagram
    participant Store as Store
    participant DT as DependencyTracker
    participant BC as Broadcaster
    participant User as User Listener

    rect rgb(200, 220, 255)
        Note over Store: Initial state:<br/>flag_b has prerequisite on flag_a<br/>DT tracks: "flag_a" → {"flag_b"} (all STRING)
    end

    Store->>DT: update_dependencies_from(FLAGS, "flag_a", new_flag_a)
    rect rgb(200, 220, 255)
        Note over DT: Refresh flag_a's own deps<br/>key = "flag_a" (STRING)
    end

    Store->>DT: add_affected_items(set, {kind: FLAGS, key: "flag_a"})
    rect rgb(200, 220, 255)
        Note over DT: Walk graph:<br/>1. "flag_a" directly changed<br/>2. "flag_b" depends on "flag_a"<br/>All keys are STRING
    end

    DT->>Store: affected = {"flag_a", "flag_b"}

    Store->>BC: FlagChange.new("flag_a")
    Store->>BC: FlagChange.new("flag_b")

    BC->>User: update(FlagChange) for each
    rect rgb(200, 220, 255)
        Note over User: .key is STRING
    end
```

### Client read path (variation call)

```mermaid
sequenceDiagram
    participant App as Application
    participant Client as LDClient
    participant Store as Store
    participant Mem as InMemoryStore

    App->>Client: variation("my-flag", context, default)
    rect rgb(200, 220, 255)
        Note over Client: key = "my-flag" (STRING)
    end

    Client->>Store: get(FEATURES, "my-flag")
    Store->>Mem: get(FEATURES, "my-flag")
    rect rgb(255, 248, 200)
        Note over Mem: lookup: key.to_sym → :my_flag<br/>@items[:my_flag] → FeatureFlag
    end

    Mem->>Store: FeatureFlag (@key = "my-flag")
    rect rgb(200, 220, 255)
        Note over Store: FeatureFlag @key = "my-flag" (STRING)
    end
    Store->>Client: FeatureFlag
    Client->>App: evaluated value
```

## Two Distinct Key Concepts

| Concept | Type | Example | Where |
|---|---|---|---|
| **Hash key** in collections (how items are indexed in the store) | **Symbol** | `:my_flag` | `changes_to_store_data`, `InMemoryFeatureStoreV2.@items` |
| **Flag key** as a value (the flag's identifier string) | **String** | `"my-flag"` | `FeatureFlag#key`, `Prerequisite#key`, `LDClient.variation`, `FlagChange#key`, `FlagValueChange#key` |

## The Fix

1. **DELETE path** — `changes_to_store_data` now uses `.to_s` on the `:key` value field of fabricated delete hashes, matching PUT objects which carry String keys from JSON.

2. **Dependency tracker boundary** — keys are converted with `.to_s` when passed from the store to the dependency tracker, ensuring hash lookups match between items indexed by `change.key` (Symbol) and dependencies extracted from model objects (String).

3. **FlagValueChangeAdapter** — uses `.to_s` on both sides of comparisons and on the key passed to `eval_fn` and emitted in `FlagValueChange`. Users can pass either Symbol or String to `add_flag_value_change_listener`.

4. **Interface docs** — `FlagChange`, `FlagValueChange`, and `add_flag_value_change_listener` document `[String]` keys. Internal `Change` class documents that its Symbol key is converted to String at user-facing boundaries.
