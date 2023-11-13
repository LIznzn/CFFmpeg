#!/bin/sh

FFMPEG_VERSION="6.0"
DEPLOYMENT_TARGET_IOS="15.0"
DEPLOYMENT_TARGET_TVOS="17.0"
DEPLOYMENT_TARGET_MAXOSX="10.15"



# directories
SOURCE="ffmpeg-$FFMPEG_VERSION"
OUTPUT="output"
CACHE="cache"

CONFIGURE_FLAGS="--enable-cross-compile --disable-debug --disable-programs --disable-doc --enable-pic"
PLATFORMS="MacOSX iPhoneOS iPhoneSimulator AppleTVOS AppleTVSimulator"

CWD=`pwd`

echo "downloading $SOURCE"
wget -qO- https://ffmpeg.org/releases/$SOURCE.tar.xz | tar xvz

COMPILE="y"
LIPO="y"

if [ "$COMPILE" ]
then
	for PLATFORM in $PLATFORMS
	do
		if [ "$PLATFORM" = "iPhoneOS" ] || [ "$PLATFORM" = "AppleTVOS" ]
		then
			ARCHS="arm64"
		elif [ "$PLATFORM" = "MacOSX" ] || [ "$PLATFORM" = "iPhoneSimulator" ] || [ "$PLATFORM" = "AppleTVSimulator" ]
		then
			ARCHS="arm64 x86_64"
		fi
		
		for ARCH in $ARCHS
		do
			echo "building $PLATFORM $ARCH..."
			mkdir -p "$CACHE/$PLATFORM"
			cd "$CACHE/$PLATFORM"
			CFLAGS="-arch $ARCH"
			if [ "$PLATFORM" = "iPhoneOS" ]
			then
				CFLAGS="$CFLAGS -mios-version-min=$DEPLOYMENT_TARGET_IOS -fembed-bitcode"
				CONFIGURE_FLAGS="$CONFIGURE_FLAGS --disable-audiotoolbox"
			elif [ "$PLATFORM" = "iPhoneSimulator" ]
			then
				CFLAGS="$CFLAGS -mios-simulator-version-min=$DEPLOYMENT_TARGET_IOS -fembed-bitcode"
				CONFIGURE_FLAGS="$CONFIGURE_FLAGS --disable-audiotoolbox"
			elif [ "$PLATFORM" = "AppleTVOS" ]
			then
				CFLAGS="$CFLAGS -mtvos-version-min=$DEPLOYMENT_TARGET_TVOS -fembed-bitcode"
				CONFIGURE_FLAGS="$CONFIGURE_FLAGS --disable-avdevice"
			elif [ "$PLATFORM" = "AppleTVSimulator" ]
			then
				CFLAGS="$CFLAGS -mtvos-simulator-version-min=$DEPLOYMENT_TARGET_TVOS -fembed-bitcode"
				CONFIGURE_FLAGS="$CONFIGURE_FLAGS --disable-avdevice"
			elif [ "$PLATFORM" = "MacOSX" ]
			then
				CFLAGS="$CFLAGS -mmacosx-version-min=$DEPLOYMENT_TARGET_MAXOSX"
			fi
          
			XCRUN_SDK=`echo $PLATFORM | tr '[:upper:]' '[:lower:]'`
			CC="xcrun -sdk $XCRUN_SDK clang"

			if [ "$ARCH" = "x86_64" ]
			then
				AS="gas-preprocessor.pl -arch amd64 -- $CC"
			else
				AS="gas-preprocessor.pl -arch aarch64 -- $CC"
			fi

			CXXFLAGS="$CFLAGS"
			LDFLAGS="$CFLAGS"

			TMPDIR=${TMPDIR/%\/} $CWD/$SOURCE/configure \
			    --target-os=darwin \
			    --arch=$ARCH \
			    --cc="$CC" \
			    --as="$AS" \
			    $CONFIGURE_FLAGS \
			    --extra-cflags="$CFLAGS" \
			    --extra-ldflags="$LDFLAGS" \
			    --prefix="$PLATFORM/$ARCH" \
			|| exit 1

			make -j3 install $EXPORT || exit 1
			cd $CWD

			mkdir -p "$OUTPUT/$PLATFORM/$ARCH"
			cp -r "$CACHE/$PLATFORM/$PLATFORM/$ARCH" "$OUTPUT/$PLATFORM/"
			rm -r "$CACHE"
		done
	done
fi


if [ "$LIPO" ]
then
	LIBS="libavcodec libavfilter libavformat libavutil libswresample libswscale libavdevice"
	cd $OUTPUT
	for LIB in $LIBS
	do
		for PLATFORM in $PLATFORMS
		do
			if [ "$PLATFORM" = "MacOSX" ] ||[ "$PLATFORM" = "iPhoneSimulator" ] || [ "$PLATFORM" = "AppleTVSimulator" ]
			then
				mkdir -p "$PLATFORM/all/lib"
				lipo -create "$PLATFORM/arm64/lib/$LIB.a" "$PLATFORM/x86_64/lib/$LIB.a" \
		 				 -output "$PLATFORM/all/lib/$LIB.a"
		 		# cp -r "$PLATFORM/arm64/include" "$PLATFORM/all/"
			fi
			mv -v "$PLATFORM/arm64/include/$LIB" "$PLATFORM/arm64/include/$LIB-1"
			mkdir -p "$PLATFORM/arm64/include/$LIB/$LIB/"
			cp -r "$PLATFORM/arm64/include/$LIB-1/" "$PLATFORM/arm64/include/$LIB/$LIB"
		done
		#make xcframework
		if [ LIB = "libavdevice" ]
		then
			#make xcframework
			xcodebuild -create-xcframework \
	           -library iPhoneOS/arm64/lib/$LIB.a \
	           -headers iPhoneOS/arm64/include/$LIB \
	           -library iPhoneSimulator/all/lib/$LIB.a \
	           -headers iPhoneSimulator/arm64/include/$LIB \
	           -library MacOSX/all/lib/$LIB.a \
	           -headers MacOSX/arm64/include/$LIB \
	           -output $LIB.xcframework
	    else
			xcodebuild -create-xcframework \
	           -library AppleTVOS/arm64/lib/$LIB.a \
	           -headers AppleTVOS/arm64/include/$LIB \
	           -library AppleTVSimulator/all/lib/$LIB.a \
	           -headers AppleTVSimulator/arm64/include/$LIB \
	           -library iPhoneOS/arm64/lib/$LIB.a \
	           -headers iPhoneOS/arm64/include/$LIB \
	           -library iPhoneSimulator/all/lib/$LIB.a \
	           -headers iPhoneSimulator/arm64/include/$LIB \
	           -library MacOSX/all/lib/$LIB.a \
	           -headers MacOSX/arm64/include/$LIB \
	           -output $LIB.xcframework
	    fi
	done
fi

echo Done
