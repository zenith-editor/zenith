#!/bin/bash

zig_path=$(dirname $(which zig))
if [[ ! -d "$zig_path" ]]; then
  echo "zig path not found"
  exit 1
fi

package_temp=$(mktemp -d || exit 1)

SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)

git clone . $package_temp/src

mkdir -p $package_temp/src/{zig-cache,zig-out}
mkdir -p $package_temp/extra

cp -r ./docs $package_temp/docs
cp ./LICENSE $package_temp/docs
cp ./README.md $package_temp/docs

cleanup() {
  echo "Cleaning up..."
  rm -rf $package_temp
}

docker run \
  -v $zig_path:/zig \
  -v $package_temp:/app \
  -it alpine sh -c "apk add git && \
    echo \`uname -s\`-\`uname -m\` > /app/extra/arch && \
    cd /app/src && /zig/zig build -Doptimize=ReleaseSafe"
if [ $? -ne 0 ]; then
  cleanup; exit 1
fi

arch=$(cat $package_temp/extra/arch)
version=$(git describe --tags)
archive_name=zenith-$version-$arch.tar.gz 

mv $package_temp/src/zig-out/bin/zenith $package_temp/zenith
output_dir=$(pwd)/packages/
mkdir -p $output_dir
cd $package_temp
tar \
      --sort=name \
      --mtime="@${SOURCE_DATE_EPOCH}" \
      --owner=0 --group=0 --numeric-owner \
      --format=ustar \
      -cvzf $output_dir/$archive_name ./docs ./zenith
cd $output_dir
sha256sum $archive_name > SHA256SUMS

cleanup
