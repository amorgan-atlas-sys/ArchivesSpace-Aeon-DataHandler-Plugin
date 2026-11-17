#!/usr/bin/env bash
#
# Build a production-ready release zip of the aeon_data_handler plugin.
#
# Stages a clean copy of the committed tree (git archive), vendors the
# runtime gem dependencies, strips everything dev-only, and produces
# dist/aeon_data_handler-<version>.zip containing a single top-level
# aeon_data_handler/ folder ready to unzip into an ArchivesSpace plugins/
# directory.
#
# Usage: scripts/build_release.sh
# Requires: git, ruby, bundler, zip

set -euo pipefail

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
plugin_name="aeon_data_handler"

version="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["version"]' "$repo_root/plugin_info.txt")"
if [ -z "$version" ]; then
  echo "ERROR: could not read version from plugin_info.txt" >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
plugin_dir="$stage/$plugin_name"
mkdir -p "$plugin_dir"

echo "==> Staging clean copy of HEAD"
git -C "$repo_root" archive HEAD | tar -x -C "$plugin_dir"

echo "==> Vendoring runtime gems (jsonpath + multi_json)"
# Env vars (not `bundle config set`) so this works on Bundler 1.x and 2.x
# alike and leaves no .bundle/config behind.
(
  cd "$plugin_dir"
  BUNDLE_PATH=vendor/bundle BUNDLE_WITHOUT=test bundle install --quiet
)

echo "==> Normalizing vendor layout"
# The plugin's gem loaders glob vendor/bundle/ruby/*/gems/*/lib. Bundler
# writes that layout when configured via --path/config, but with the
# BUNDLE_PATH env var some versions (e.g. 1.17) install straight into
# vendor/bundle/gems. Move that into the ruby/*/ layout the loaders expect.
if [ -d "$plugin_dir/vendor/bundle/gems" ]; then
  mkdir -p "$plugin_dir/vendor/bundle/ruby/portable"
  mv "$plugin_dir/vendor/bundle/gems" "$plugin_dir/vendor/bundle/ruby/portable/gems"
  find "$plugin_dir/vendor/bundle" -mindepth 1 -maxdepth 1 ! -name ruby -exec rm -rf {} +
fi
if ! ls "$plugin_dir"/vendor/bundle/ruby/*/gems/jsonpath-*/lib >/dev/null 2>&1; then
  echo "ERROR: vendored jsonpath not found under vendor/bundle/ruby/*/gems" >&2
  exit 1
fi

echo "==> Pruning bundler artifacts not needed at runtime"
# The loaders only add vendor/bundle/ruby/*/gems/*/lib to $LOAD_PATH, so
# everything else bundler produces is dead weight in the zip.
for dir in cache doc specifications build_info extensions bin plugins; do
  rm -rf "$plugin_dir"/vendor/bundle/ruby/*/"$dir"
done

echo "==> Stripping dev-only and documentation files"
(
  cd "$plugin_dir"
  # Gemfile/Gemfile.lock/.bundle MUST NOT ship: ArchivesSpace evaluates plugin
  # Gemfiles into its own bundle and the dev gem pins conflict with AS's gems.
  rm -rf Gemfile Gemfile.lock .bundle spec .github scripts \
         Legacy docs README.md .rubocop.yml .gitignore ./*.pdf
)

echo "==> Creating zip"
mkdir -p "$repo_root/dist"
zip_path="$repo_root/dist/$plugin_name-$version.zip"
rm -f "$zip_path"
(cd "$stage" && zip -rq "$zip_path" "$plugin_name")

echo "Built $zip_path"
unzip -l "$zip_path" | tail -1
