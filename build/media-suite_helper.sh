#!/bin/bash

vcs_clone() {
    if [[ "$vcsType" = "svn" ]]; then
        svn checkout -r "$ref" "$vcsURL" "$vcsFolder"-svn
    else
        "$vcsType" clone "$vcsURL" "$vcsFolder-$vcsType"
    fi
}

vcs_update() {
    if [[ "$vcsType" = "svn" ]]; then
        oldHead=$(svnversion)
        svn update -r "$ref"
        newHead=$(svnversion)
    elif [[ "$vcsType" = "hg" ]]; then
        oldHead=$(hg id --id)
        hg pull
        hg update -C -r "$ref"
        newHead=$(hg id --id)
    elif [[ "$vcsType" = "git" ]]; then
        local unshallow=""
        [[ -f .git/shallow ]] && unshallow="--unshallow"
        [[ "$vcsURL" != "$(git config --get remote.origin.url)" ]] &&
            git remote set-url origin "$vcsURL"
        [[ "ab-suite" != "$(git rev-parse --abbrev-ref HEAD)" ]] && git reset -q --hard @{u}
        [[ "$(git config --get remote.origin.fetch)" = "+refs/heads/master:refs/remotes/origin/master" ]] &&
            git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
        git checkout -qf --no-track -B ab-suite "$ref"
        git fetch -qt $unshallow origin
        oldHead=$(git rev-parse HEAD)
        git checkout -qf --no-track -B ab-suite "$ref"
        newHead=$(git rev-parse HEAD)
    fi
}

vcs_log() {
    if [[ "$vcsType" = "git" ]]; then
        git log --no-merges --pretty="%ci %h %s" \
            --abbrev-commit "$oldHead".."$newHead" >> "$LOCALBUILDDIR"/newchangelog
    elif [[ "$vcsType" = "hg" ]]; then
        hg log --template "{date|localdate|isodatesec} {node|short} {desc|firstline}\n" \
            -r "reverse($oldHead:$newHead)" >> "$LOCALBUILDDIR"/newchangelog
    fi
}

# get source from VCS
# example:
#   do_vcs "url#branch|revision|tag|commit=NAME" "folder" "lib/libname.a"
do_vcs() {
    local vcsType="${1%::*}"
    local vcsURL="${1#*::}"
    [[ "$vcsType" = "$vcsURL" ]] && vcsType="git"
    local vcsBranch="${vcsURL#*#}"
    [[ "$vcsBranch" = "$vcsURL" ]] && vcsBranch=""
    local vcsFolder="$2"
    local vcsCheck="$3"
    local ref=""
    if [[ -n "$vcsBranch" ]]; then
        vcsURL="${vcsURL%#*}"
        case ${vcsBranch%%=*} in
            commit|tag|revision)
                ref=${vcsBranch##*=}
                ;;
            branch)
                ref=origin/${vcsBranch##*=}
                ;;
        esac
    else
        if [[ "$vcsType" = "git" ]]; then
            ref="origin/HEAD"
        elif [[ "$vcsType" = "hg" ]]; then
            ref="tip"
        elif [[ "$vcsType" = "svn" ]]; then
            ref="HEAD"
        fi
    fi
    compile="false"

    echo -ne "\033]0;compiling $vcsFolder $bits\007"
    if [ ! -d "$vcsFolder-$vcsType" ]; then
        vcs_clone
        if [[ -d "$vcsFolder-$vcsType" ]]; then
            cd "$vcsFolder-$vcsType"
            touch recently_updated
        else
            echo "$vcsFolder $vcsType seems to be down"
            echo "Try again later or <Enter> to continue"
            do_prompt "if you're sure nothing depends on it."
            return
        fi
    else
        cd "$vcsFolder-$vcsType"
    fi
    vcs_update
    if [[ "$oldHead" != "$newHead" ]]; then
        touch recently_updated
        rm -f build_successful{32,64}bit
        if [[ $build32 = "yes" && $build64 = "yes" ]] && [[ $bits = "64bit" ]]; then
            new_updates="yes"
            new_updates_packages="$new_updates_packages [$vcsFolder]"
        fi
        echo "$vcsFolder" >> "$LOCALBUILDDIR"/newchangelog
        vcs_log
        echo "" >> "$LOCALBUILDDIR"/newchangelog
        compile="true"
    elif [[ -f recently_updated && ! -f "build_successful$bits" ]] ||
         [[ -z "$vcsCheck" && ! -f "$LOCALDESTDIR/lib/pkgconfig/$vcsFolder.pc" ]] ||
         [[ ! -z "$vcsCheck" && ! -f "$LOCALDESTDIR/$vcsCheck" ]]; then
        compile="true"
    else
        echo -------------------------------------------------
        echo "$vcsFolder is already up to date"
        echo -------------------------------------------------
    fi
}

# get wget download
do_wget() {
    local url="$1"
    local archive="$2"
    local dirName="$3"
    if [[ -z $archive ]]; then
        # remove arguments and filepath
        archive=${url%%\?*}
        archive=${archive##*/}
    fi
    # accepted: zip, 7z, tar.gz, tar.bz2 and tar.xz
    local archive_type=$(expr $archive : '.\+\(tar\(\.\(gz\|bz2\|xz\)\)\?\|7z\|zip\)$')
    [[ -z "$dirName" ]] && dirName=$(expr $archive : '\(.\+\)\.\(tar\(\.\(gz\|bz2\|xz\)\)\?\|7z\|zip\)$')
    if [[ -d "$dirName" && $archive_type = tar* ]] &&
        { [[ $build32 = "yes" && ! -f "$dirName"/build_successful32bit ]] ||
          [[ $build64 = "yes" && ! -f "$dirName"/build_successful64bit ]]; }; then
        rm -rf $dirName
    fi
    local response_code=$(curl --retry 20 --retry-max-time 5 -L -k -f -w "%{response_code}" -o "$archive" "$url")
    if [[ $response_code = "200" || $response_code = "226" ]]; then
        case $archive_type in
        zip)
            unzip "$archive"
            [[ $deleteSource = "y" ]] && rm "$archive"
            ;;
        7z)
            7z x -o"$dirName" "$archive"
            [[ $deleteSource = "y" ]] && rm "$archive"
            ;;
        tar*)
            tar -xaf "$archive"
            [[ $deleteSource = "y" ]] && rm "$archive"
            cd "$dirName"
            ;;
        esac
    elif [[ $response_code -gt 400 ]]; then
        echo "Error $response_code while downloading $URL"
        echo "Try again later or <Enter> to continue"
        do_prompt "if you're sure nothing depends on it."
    fi
}

# check if compiled file exist
do_checkIfExist() {
    local packetName="$1"
    local fileName="$2"
    local fileExtension=${fileName##*.}
    local buildSuccess="n"

    if [[ "$fileExtension" = "a" ]] || [[ "$fileExtension" = "dll" ]]; then
        if [ -f "$LOCALDESTDIR/lib/$fileName" ]; then
            buildSuccess="y"
        fi
    else
        if [ -f "$LOCALDESTDIR/$fileName" ]; then
            buildSuccess="y"
        fi
    fi

    if [[ $buildSuccess = "y" ]]; then
        echo -
        echo -------------------------------------------------
        echo "build $packetName done..."
        echo -------------------------------------------------
        echo -
        if [[ -d "$LOCALBUILDDIR/$packetName" ]]; then
            touch $LOCALBUILDDIR/$packetName/build_successful$bits
        fi
    else
        if [[ -d "$LOCALBUILDDIR/$packetName" ]]; then
            rm -f $LOCALBUILDDIR/$packetName/build_successful$bits
        fi
        echo -------------------------------------------------
        echo "Build of $packetName failed..."
        echo "Delete the source folder under '$LOCALBUILDDIR' and start again."
        echo "If you're sure there are no dependencies <Enter> to continue building."
        do_prompt "Close this window if you wish to stop building."
    fi
}

do_pkgConfig() {
    local pkg=${1%% *}
    echo -ne "\033]0;compiling $pkg $bits\007"
    local prefix=$(pkg-config --variable=prefix --silence-errors "$1")
    [[ ! -z "$prefix" ]] && prefix="$(cygpath -u "$prefix")"
    if [[ "$prefix" = "$LOCALDESTDIR" || "$prefix" = "/trunk${LOCALDESTDIR}" ]]; then
        echo -------------------------------------------------
        echo "$pkg is already compiled"
        echo -------------------------------------------------
        return 1
    fi
}

do_getFFmpegConfig() {
    configfile="$LOCALBUILDDIR"/ffmpeg_options.txt
    if [[ -f "$configfile" ]] && [[ $ffmpegChoice = "y" ]]; then
        FFMPEG_OPTS="$FFMPEG_BASE_OPTS $(cat "$configfile" | sed -e 's:\\::g' -e 's/#.*//')"
    else
        FFMPEG_OPTS="$FFMPEG_BASE_OPTS $FFMPEG_DEFAULT_OPTS"
    fi

    if [[ $bits = "32bit" ]]; then
        arch=x86
    else
        arch=x86_64
    fi
    export arch

    # prefer openssl if both are in options and nonfree
    if do_checkForOptions "--enable-openssl" && [[ $nonfree = "y" ]]; then
        do_removeOption "--enable-gnutls"
        do_removeOption "--enable-libutvideo"
    # prefer gnutls if both are in options and free
    elif do_checkForOptions "--enable-openssl"; then
        do_removeOption "--enable-openssl"
        do_addOption "--enable-gnutls"
    # add openssl if neither are in options and librtmp is and nonfree
    elif ! do_checkForOptions "--enable-openssl --enable-gnutls" &&
         do_checkForOptions "--enable-librtmp" && [[ $nonfree = "y" ]]; then
        do_addOption "--enable-openssl"
        do_removeOption "--enable-libutvideo"
    # add gnutls if free
    else
        do_addOption "--enable-gnutls"
    fi
}

do_changeFFmpegConfig() {
    # add options for static kvazaar
    if do_checkForOptions "--enable-libkvazaar"; then
        do_addOption "--extra-cflags=-DKVZ_STATIC_LIB"
    fi

    # handle gplv3 libs
    if do_checkForOptions "--enable-libopencore-amrwb --enable-libopencore-amrnb \
        --enable-libvo-aacenc --enable-libvo-amrwbenc"; then
        do_addOption "--enable-version3"
    fi

    # handle non-free libs
    if [[ $nonfree = "y" ]] && do_checkForOptions "--enable-libfdk-aac --enable-nvenc \
        --enable-libfaac --enable-openssl"; then
        do_addOption "--enable-nonfree"
    else
        do_removeOption "--enable-nonfree"
        do_removeOption "--enable-libfdk-aac"
        do_removeOption "--enable-nvenc"
        do_removeOption "--enable-libfaac"
    fi

    if do_checkForOptions "--enable-frei0r"; then
        do_addOption "--enable-filter=frei0r"
    fi

    # remove libmfx if compiling with xp compatibility
    if [[ $xpcomp = "y" ]]; then
        do_removeOption "--enable-libmfx"
    fi

    # remove libs that don't work with shared
    if [[ $ffmpeg = "s" || $ffmpeg = "b" ]]; then
        FFMPEG_OPTS_SHARED=$FFMPEG_OPTS
        do_removeOption "--enable-decklink" y
        do_removeOption "--enable-libutvideo" y
        do_removeOption "--enable-libgme" y
        do_addOption    "--extra-ldflags=-static-libgcc" y
    fi
}

do_checkForOptions() {
    local isPresent=1
    for option in "$@"; do
        for option2 in $option; do
            if echo "$FFMPEG_OPTS" | grep -q -E -e "$option2"; then
                isPresent=0
            fi
        done
    done
    return $isPresent
}

do_addOption() {
    local option=${1%% *}
    if ! do_checkForOptions "$option"; then
        FFMPEG_OPTS="$FFMPEG_OPTS $option"
    fi
}

do_removeOption() {
    local option=${1%% *}
    local shared=$2
    if [[ $shared = "y" ]]; then
        FFMPEG_OPTS_SHARED=$(echo "$FFMPEG_OPTS_SHARED" | sed "s/ *$option//g")
    else
        FFMPEG_OPTS=$(echo "$FFMPEG_OPTS" | sed "s/ *$option//g")
    fi
}

do_patch() {
    local patch=${1%% *}
    local am=$2     # "am" to apply patch with "git am"
    local strip=$3  # value of "patch" -p i.e. leading directories to strip
    if [[ -z $strip ]]; then
        strip="1"
    fi
    local patchpath=""
    local response_code="$(curl --retry 20 --retry-max-time 5 -L -k -f -w "%{response_code}" \
        -O "https://raw.github.com/jb-alvarado/media-autobuild_suite/master${LOCALBUILDDIR}/patches/$patch")"

    if [[ $response_code != "200" ]]; then
        echo "Patch not found online. Trying local patch. Probably not up-to-date."
        if [[ -f ./"$patch" ]]; then
            patchpath="$patch"
        elif [[ -f "$LOCALBUILDDIR/patches/${patch}" ]]; then
            patchpath="$LOCALBUILDDIR/patches/${patch}"
        fi
    else
        patchpath="$patch"
    fi
    if [[ "$patchpath" != "" ]]; then
        [[ "$am" = "am" ]] && git am "$patchpath" || patch -N -p$strip -i "$patchpath"
    else
        echo "No patch found anywhere. Moving on without patching."
    fi
}

do_cmake() {
    if [ -d "build" ]; then
        rm -rf ./build/*
    else
        mkdir build
    fi
    cd build
    cmake .. -G Ninja -DBUILD_SHARED_LIBS=off -DCMAKE_INSTALL_PREFIX="$LOCALDESTDIR" -DUNIX=on "$@"
}

do_generic_conf() {
    local bindir=""
    case "$1" in
    global)
        bindir="--bindir=$LOCALDESTDIR/bin-global"
        ;;
    audio)
        bindir="--bindir=$LOCALDESTDIR/bin-audio"
        ;;
    video)
        bindir="--bindir=$LOCALDESTDIR/bin-video"
        ;;
    *)
        bindir="$1"
        ;;
    esac
    shift 1
    ./configure --build=$targetBuild --prefix=$LOCALDESTDIR --disable-shared "$bindir" "$@"
}

do_makeinstall() {
    make -j $cpuCount "$@"
    make install
}

do_generic_confmakeinstall() {
    do_generic_conf "$@"
    do_makeinstall
}

do_hide_pacman_sharedlibs() {
    local packages="$1"
    local revert="$2"
    local files=$(pacman -Qql $packages 2>/dev/null | grep .dll.a)

    for file in $files; do
        if [[ -f "$file" && -f "${file%*.dll.a}.a" ]]; then
            mv -f "${file}" "${file}.dyn"
        elif [[ -n "$revert" && -f "${file}.dyn" ]]; then
            mv -f "${file}.dyn" "${file}"
        fi
    done
}

do_hide_all_sharedlibs() {
    [[ x"$1" = "xdry" ]] && local dryrun="y"
    local files=$(find /mingw{32,64} -name *.dll.a)
    for file in $files; do
        [[ -f "${file%*.dll.a}.a" ]] &&
            { [[ $dryrun != "y" ]] && mv -f "${file}" "${file}.dyn" || echo "${file}"; }
    done
}

do_pacman_install() {
    local packages="$1"
    echo "Installing dependencies as needed:"
    local sed=""
    [[ $build32 = "yes" ]] && sed+="mingw-w64-i686-&"
    [[ $build64 = "yes" ]] && sed+=" mingw-w64-x86_64-&"
    local mingwpackages="$(echo $packages | sed -r "s/\S+/$sed/g")"
    pacman -S --noconfirm --needed $mingwpackages 2>/dev/null
    do_hide_all_sharedlibs
    pacman -D --asexplicit $mingwpackages >/dev/null
    for pkg in $packages; do
        grep -q "$pkg" /etc/pac-mingw-extra.pk || echo "$pkg" >> /etc/pac-mingw-extra.pk
    done
}

do_pacman_remove() {
    local packages="$1"
    [[ $build32 = "yes" ]] && sed+="mingw-w64-i686-&"
    [[ $build64 = "yes" ]] && sed+=" mingw-w64-x86_64-&"
    local mingwpackages="$(echo $packages | sed -r "s/\S+/$sed/g")"
    do_hide_pacman_sharedlibs "$mingwpackages" revert
    local deps=""
    for mingwpkg in $mingwpackages; do
        pacman -Qs $mingwpkg >/dev/null && pacman -Rs --noconfirm $mingwpkg >/dev/null
        pacman -Qs $mingwpkg >/dev/null && deps+=" $mingwpkg"
    done
    [[ -n "$deps" ]] && pacman -D --noconfirm --asdeps $deps >/dev/null
    for pkg in $packages; do
        grep -q "$pkg" /etc/pac-mingw-extra.pk && sed -i "/${pkg}/d" /etc/pac-mingw-extra.pk
    done
}

do_prompt() {
    # from http://superuser.com/a/608509
    while read -s -e -t 0.1; do : ; done
    read -p "$1" ret
}
