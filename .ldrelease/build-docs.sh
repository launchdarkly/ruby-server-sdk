#!/bin/bash

# doc generation is not part of Releaser's standard Ruby project template

mkdir -p ./artifacts/

cd ./docs
make
cd ..

# Releaser will pick up docs generated in CI if we put an archive of them in the
# artifacts directory and name it docs.tar.gz or docs.zip. They will be uploaded
# to GitHub Pages and also attached as release artifacts. There's no separate
# "publish-docs" step because the external service that also hosts them doesn't
# require an upload, it just picks up gems automatically.

cd ./docs/build/html
tar cfz ../../../artifacts/docs.tar.gz *
