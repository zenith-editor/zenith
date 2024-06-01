#!/bin/bash

zig_path=$(dirname $(which zig))
if [[ ! -d "$zig_path" ]]; then
  echo "zig path not found"
  exit 1
fi

package_temp=$(mktemp -d || exit 1)

mkdir $package_temp/zig-out
mkdir $package_temp/extra

cp -r ./docs $package_temp/docs
cp ./LICENSE $package_temp/docs
cp ./README.md $package_temp/docs

cleanup() {
  echo "Cleaning up..."
  rm -rf $package_temp
}

[[ -L "./zig-cache" ]] && rm zig-cache && mkdir zig-cache

docker run \
  -v $zig_path:/zig \
  -v .:/app \
  --tmpfs /app/zig-cache:size=512m \
  -v $package_temp/zig-out:/app/zig-out \
  -v $package_temp/extra:/extra \
  -it alpine sh -c "apk add git && echo \`uname -s\`-\`uname -m\` > /extra/arch && cd /app && /zig/zig build  -Doptimize=ReleaseSafe"
if [ $? -ne 0 ]; then
  cleanup; exit 1
fi

arch=$(cat $package_temp/extra/arch)
version=$(git describe --tags)
mv $package_temp/zig-out/bin/zenith $package_temp/zenith
old_pwd=$(pwd)
cd $package_temp
tar -cvzf $old_pwd/zenith-$version-$arch.tar.gz ./docs ./zenith
cd $old_pwd

cleanup
