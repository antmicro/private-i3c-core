#!/bin/bash

set -eux
set -o pipefail

# Needed for Coverview
NODE_SHA=872150825071bb403b6e210c66d9487a791047d0299026de429eb1f626fd969f

curl -O https://deb.nodesource.com/setup_24.x
if ! [ "$(sha256sum setup_24.x | cut -d' ' -f1)" = "${NODE_SHA}" ]; then
    echo "NodeJS checksum mismatch!" 1>&2
    exit 1
fi

chmod +x setup_24.x
./setup_24.x
sudo apt -qqy install nodejs

python3 -m pip install git+https://github.com/antmicro/info-process.git
git clone https://github.com/antmicro/coverview.git

find ./artifacts/coverage/ -name '*.info' -exec \
  info-process transform --strip-file-prefix '(^/root/.*i3c-core/|^/root/|^/ci/)' --filter '^src/' '{}' \;
for sim in v verilator; do
  if [ `find ./artifacts/coverage/ -name "*_${sim}.info" | wc -l` -eq 0 ]; then
    echo "No *_${sim}.info files found, skipping $sim"
    continue
  fi
  for typ in line branch cond toggle; do
    echo "Merging ${typ}_${sim}..."
    # Common prefix, i.e. `artifacts/coverage/`, is going to be stripped automatically.
    find artifacts/coverage/ -name "*_${typ}_${sim}.info" | xargs info-process merge --output "coverage_${typ}_${sim}.info" \
      --test-list "tests_${typ}_${sim}.desc"
    _coverage_files+=" $PWD/coverage_${typ}_${sim}.info"
    if [ "${sim}" = verilator -a "${typ}" = toggle ]; then
      EXTRA_TRANSFORM_ARGS='--add-missing-brda-entries --add-two-way-toggles'
    else
      EXTRA_TRANSFORM_ARGS=''
    fi
    info-process transform --normalize-hit-counts ${EXTRA_TRANSFORM_ARGS} "coverage_${typ}_${sim}.info"
  done
done
pushd coverview
  npm install
  echo -n "{\"title\": \"I3C coverage dashboard\"," > config.json
  echo -n "\"commit\": \"${GITHUB_SHA}\"," >> config.json
  echo -n "\"branch\": \"${GITHUB_REF_NAME}\"," >> config.json
  echo -n "\"repo\": \"${GITHUB_REPOSITORY}\"," >> config.json
  echo -n "\"timestamp\": \"$(date +%Y-%m-%dT%H:%M:%S.%3N%z)\"}" >> config.json
  # The order of the files provided into `--coverage-files` sets which simulator results will be shown first
  info-process pack --output data_both.zip --config config.json --sources-root .. \
    --coverage-files $_coverage_files --description-files ../*.desc
  ls -la data_both.zip

  npm run build
  ./embed.py --inject-data data_both.zip
  mkdir -p ../doc/build/html  # In case `make verification-docs-with-sim` wasn't run
  cp dist/index.html ../doc/build/html/coverview.html

  if ls ../*_v.info &>/dev/null; then
    info-process pack --output data_v.zip --config config.json --sources-root .. \
      --coverage-files ../*_v.info --description-files ../*_v.desc
  fi
popd

# Static webpage available at: doc/build/html/
# It can be uploaded with artifacts step
# data_both.zip is the source of the coverage for Coverview static dashboard
