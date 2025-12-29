#!/bin/bash
set -ef
GROUP=
group() {
	endgroup
	echo "::group::  $1"
	GROUP=1
}
endgroup() {
	if [ -n "$GROUP" ]; then
		echo "::endgroup::"
	fi
	GROUP=
}
trap 'endgroup' ERR

group "download setup.sh"
wget -O setup.tar.gz https://codeload.github.com/openwrt/docker/tar.gz/refs/heads/main
tar xf setup.tar.gz --strip=1 --no-same-owner -C .
rm -vrf setup.tar.gz

sed -i 's|/builder/keys/|keys/|g' setup.sh
sed -i '/wget .*\$file_name/{s|wget -nv|axel -q -H "'"User-Agent: $USER_AGENT"'" -n8|g}' setup.sh

echo -e "\nsetup.sh START"
cat setup.sh
echo -e "setup.sh END\n"
endgroup

group "bash setup.sh"
# snapshot containers don't ship with the SDK to save bandwidth
# run setup.sh to download and extract the SDK
bash setup.sh
endgroup

# Initialize bin/ dl/ feeds/ logs/ symlike
for d in bin logs; do
	mkdir -p $artifacts_dir/$d 2>/dev/null
	ln -s $artifacts_dir/$d $d
done
[ -z "$FEEDS_DIR" ] || ln -s "$FEEDS_DIR" feeds
[ -z "$DL_DIR" ] || { rm -rf dl; ln -s "$DL_DIR" dl; }

FEEDNAME="${FEEDNAME:-action}"
BUILD_LOG="${BUILD_LOG:-1}"

# opkg key-build
if [ -n "$KEY_BUILD" ]; then
	echo "$KEY_BUILD" > key-build
	CONFIG_SIGNED_PACKAGES="y"
fi

if [ -z "$NO_DEFAULT_FEEDS" ]; then
	sed \
		-e 's,https://git.openwrt.org/feed/,https://github.com/openwrt/,' \
		-e 's,https://git.openwrt.org/openwrt/,https://github.com/openwrt/,' \
		-e 's,https://git.openwrt.org/project/,https://github.com/openwrt/,' \
		feeds.conf.default > feeds.conf
fi

ALL_CUSTOM_FEEDS=

if [ -z "$NO_REPO_FEEDS" ]; then
	echo "src-link $FEEDNAME $feed_dir/" >> feeds.conf
	ALL_CUSTOM_FEEDS+="$FEEDNAME "
fi

#shellcheck disable=SC2153
for EXTRA_FEED in $EXTRA_FEEDS; do
	tr '|' ' ' <<< "$EXTRA_FEED" >> feeds.conf
	ALL_CUSTOM_FEEDS+="$(cut -f2 -d'|' <<< "$EXTRA_FEED") "
done

group "feeds.conf"
cat feeds.conf
endgroup

group "feeds update -a"
err=1 && rtry=0 && until [ $err = 0 -o $rtry -gt 10 ]; do
	./scripts/feeds update -a && err=0 || { err=$?; let rtry++; }
done
endgroup

group "make defconfig"
make defconfig
endgroup

group "llvm.download-ci-llvm fix"
# Set Rust build arg llvm.download-ci-llvm to false.
unCI() {
	unset CI GITHUB_ACTIONS
	local func="$1"; shift
	if [ -n "$func" ]; then
		"$func" "$@"
	fi
}
#sed -i 's|\(--set=llvm\.download-ci-llvm\)=true|\1=false|' feeds/packages/lang/rust/Makefile
endgroup

if [ -z "$PACKAGES" ]; then
	# compile all packages in feed
	for FEED in $ALL_CUSTOM_FEEDS; do
		group "feeds install -p $FEED -f -a"
		./scripts/feeds install -p "$FEED" -f -a
		endgroup
	done

	RET=0

	make \
		BUILD_LOG="$BUILD_LOG" \
		CONFIG_SIGNED_PACKAGES="$CONFIG_SIGNED_PACKAGES" \
		IGNORE_ERRORS="$IGNORE_ERRORS" \
		CONFIG_AUTOREMOVE=y \
		V="$V" \
		-j "$(nproc)" || RET=$?
else
	# compile specific packages with checks
	for PKG in $PACKAGES; do
		for FEED in $ALL_CUSTOM_FEEDS; do
			group "feeds install -p $FEED -f $PKG"
			./scripts/feeds install -p "$FEED" -f "$PKG"
			endgroup
		done

		group "make package/$PKG/download"
		make \
			BUILD_LOG="$BUILD_LOG" \
			IGNORE_ERRORS="$IGNORE_ERRORS" \
			"package/$PKG/download" V=s
		endgroup

		group "make package/$PKG/check"
		make \
			BUILD_LOG="$BUILD_LOG" \
			IGNORE_ERRORS="$IGNORE_ERRORS" \
			"package/$PKG/check" V=s 2>&1 | \
				tee logtmp
		endgroup

		RET=${PIPESTATUS[0]}

		if [ "$RET" -ne 0 ]; then
			echo_red   "=> Package check failed: $RET)"
			exit "$RET"
		fi

		badhash_msg="HASH does not match "
		badhash_msg+="|HASH uses deprecated hash,"
		#badhash_msg+="|HASH is missing,"
		if grep -qE "$badhash_msg" logtmp; then
			echo "Package HASH check failed"
			exit 1
		fi

		PATCHES_DIR=$(find $feed_dir -path "*/$PKG/patches")
		if [ -d "$PATCHES_DIR" ] && [ -z "$NO_REFRESH_CHECK" ]; then
			group "make package/$PKG/refresh"
			make \
				BUILD_LOG="$BUILD_LOG" \
				IGNORE_ERRORS="$IGNORE_ERRORS" \
				"package/$PKG/refresh" V=s
			endgroup

			if ! git -C "$PATCHES_DIR" diff --quiet -- .; then
				echo "Dirty patches detected, please refresh and review the diff"
				git -C "$PATCHES_DIR" checkout -- .
				exit 1
			fi

			group "make package/$PKG/clean"
			make \
				BUILD_LOG="$BUILD_LOG" \
				IGNORE_ERRORS="$IGNORE_ERRORS" \
				"package/$PKG/clean" V=s
			endgroup
		fi

		FILES_DIR=$(find $feed_dir -path "*/$PKG/files")
		if [ -d "$FILES_DIR" ] && [ -z "$NO_SHFMT_CHECK" ]; then
			find "$FILES_DIR" -name "*.init" -exec shfmt -w -sr -s '{}' \;
			if ! git -C "$FILES_DIR" diff --quiet -- .; then
				echo "init script must be formatted. Please run through shfmt -w -sr -s"
				git -C "$FILES_DIR" checkout -- .
				exit 1
			fi
		fi

	done

	make \
		-f .config \
		-f tmp/.packagedeps \
		-f <(echo "\$(info \$(sort \$(package-y) \$(package-m)))"; echo -en "a:\n\t@:") \
			| tr ' ' '\n' > enabled-package-subdirs.txt

	RET=0

	for PKG in $PACKAGES; do
		if ! grep -m1 -qE "(^|/)$PKG$" enabled-package-subdirs.txt; then
			echo "::warning file=$PKG::Skipping $PKG due to unsupported architecture"
			continue
		fi

		group "make package/$PKG/compile"
		unCI make \
			BUILD_LOG="$BUILD_LOG" \
			IGNORE_ERRORS="$IGNORE_ERRORS" \
			CONFIG_AUTOREMOVE=y \
			V="$V" \
			-j "$(nproc)" \
			"package/$PKG/compile" || {
				RET=$?
				break
			}
		endgroup
	done
fi

if [ "$INDEX" = '1' ];then
	group "make package/index"
	make package/index
	endgroup
fi

exit "$RET"
