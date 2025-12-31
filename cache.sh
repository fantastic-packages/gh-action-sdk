#!/bin/bash
set -e
# ref shetup.sh
# the inputs:
TARGET="${TARGET:-x86/64}"
VERSION_PATH="${VERSION_PATH:-snapshots}"
FILE_HOST="${UPSTREAM_URL:-${FILE_HOST:-https://downloads.openwrt.org}}"
DOWNLOAD_FILE="${DOWNLOAD_FILE:-imagebuilder-.*x86_64.tar.[xz|zst]}"
DOWNLOAD_PATH="$VERSION_PATH/targets/$TARGET"

wget -nv "$FILE_HOST/$DOWNLOAD_PATH/sha256sums" -O sha256sums

# determine archive name
file_name="$(grep "$DOWNLOAD_FILE" sha256sums | cut -d "*" -f 2)"
file_hash="$(grep "$DOWNLOAD_FILE" sha256sums | cut -d " " -f 1)"

# check and get imagebuilder/sdk archive
need_update=1
if [ -f "$file_hash" ]; then
	# processing fragments (if exists)
	[ ! -f "${file_name}.aa" ] || cat ${file_name}.* > $file_name
	# check hash
	if sha256sum -c $file_hash; then
		need_update=
		echo "IB/SDK cache has been used"
	fi
fi
#
if [ -n "$need_update" ]; then
	echo "IB/SDK downloading"
	rm -vrf $file_name ${file_name}.*
	err=1 && until [ $err = 0 ]; do
		axel -q -H "User-Agent: $USER_AGENT" -n8 "$FILE_HOST/$DOWNLOAD_PATH/$file_name"
		grep -qi "$file_hash" <<< "$(sha256sum $file_name | cut -f1 -d" ")" && err=0 || err=$?
	done
	echo "IB/SDK download successful"
fi
# Take out imagebuilder/sdk archive
cp $file_name $GITHUB_WORKSPACE/$WORKING_DIRECTORY_NAME/

# update imagebuilder/sdk cache
if [ -n "$need_update" ]; then
	echo "IB/SDK uploading"
	git reset --mixed HEAD~1
	find * -maxdepth 1 -not -name "$file_name" -exec rm -vrf {} \;
	echo "$file_hash *$file_name" > $file_hash
	# processing fragments (if need)
	if [ $(wc -c $file_name | awk '{print $1}') -gt $(( $SINGLE_FILE_LIMIT * 1024 ** 2 )) ]; then
		split -b ${SINGLE_FILE_LIMIT}m $file_name ${file_name}.
		rm -vrf $file_name
	fi
	git add .
	git commit -m "Upload IB/SDK cache"
	git push -f
	echo "IB/SDK upload successful"
fi
