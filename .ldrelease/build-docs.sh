#!/bin/bash

# doc generation is not part of Releaser's standard Ruby project template

cd ./docs
make
cd build/html

# Releaser will pick up generated docs if we put them in the designated
# directory. They will be uploaded to GitHub Pages and also attached as
# release artifacts. There's no separate "publish-docs" step because the
# external service that also hosts them doesn't require an upload, it just
# picks up gems automatically.

cp -r * "${LD_RELEASE_DOCS_DIR}"
