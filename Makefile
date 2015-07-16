# Simple makefile to allow command line compilation.
#
# Only tested on OSX but the principle should work everywhere.

# Set these to your paths.
MXMLC="/Applications/Adobe Flash Builder 4.7/sdks/4.6.0/bin/mxmlc"
COMPC="/Applications/Adobe Flash Builder 4.7/sdks/4.6.0/bin/compc"
flexlib="/Applications/Adobe Flash Builder 4.7/sdks/4.6.0/"

DEBUG_FLAG=true
OPTIMIZE_FLAG=false

# First time, run make disabled all
# Then only need to run disable if you change OSMF or OSMFUtils	
all: TestPlayer/html-template/TestPlayer.swf KalturaHLSPlugin/KalturaHLSPlugin.swf

TestPlayer/html-template/TestPlayer.swf: $(shell find TestPlayer -name \*.as) $(shell find TestPlayer -name \*.mxml) HLSPlugin/hlsPlugin.swc
	@echo ============ TestPlayer ========================
	cd TestPlayer && ${MXMLC} \
		-static-link-runtime-shared-libraries=true \
		-library-path+=../OSMF/osmf.swc \
		-library-path+=../OSMFUTils/osmfutils.swc \
		-library-path+=../HLSPlugin/libs/aes-decrypt.swc \
		-library-path+=../hlsPlugin/hlsPlugin.swc \
		-swf-version 20 \
		-use-network=true \
		-debug=${DEBUG_FLAG} \
		-optimize=${OPTIMIZE_FLAG} \
		-output html-template/TestPlayer.swf -source-path+=src src/DashTest.mxml

KalturaHLSPlugin/KalturaHLSPlugin.swf: $(shell find KalturaHLSPlugin -name \*.as) HLSPlugin/hlsPlugin.swc
	@echo ============ KalturaHLSPlugin ========================
	cd KalturaHLSPlugin && ${MXMLC} \
		-static-link-runtime-shared-libraries=true \
		-library-path+=../OSMF/osmf.swc \
		-library-path+=../OSMFUTils/osmfutils.swc \
		-library-path+=../HLSPlugin/libs/aes-decrypt.swc \
		-library-path+=../hlsPlugin/hlsPlugin.swc \
		-library-path+=lib/lightKdp3Lib.swc \
		-swf-version 20 \
		-use-network=true \
		-debug=${DEBUG_FLAG} \
		-optimize=${OPTIMIZE_FLAG} \
		-output KalturaHLSPlugin.swf -source-path+=src src/KalturaHLSPlugin.as

HLSPlugin/hlsPlugin.swc: $(shell find HLSPlugin/ -name \*.as) OSMFUtils/osmfutils.swc
	@echo ============= HLSPlugin ========================
	cd HLSPlugin && ${COMPC} \
		-load-config+=HLS-build-config.xml \
		-library-path+=../OSMF/osmf.swc \
		-library-path+=libs/aes-decrypt.swc \
		-swf-version 20 \
		-use-network=true \
		-debug=${DEBUG_FLAG} \
		-optimize=${OPTIMIZE_FLAG} \
		-output hlsPlugin.swc -include-sources src

OSMFUtils/osmfutils.swc: $(shell find OSMFUtils/ -name \*.as) OSMF/osmf.swc
	@echo ============= OSMFUtils ========================
	cd OSMFUtils && ${COMPC} \
		-load-config+=OSMFUtils-build-config.xml \
		-swf-version 20 \
		-debug=${DEBUG_FLAG} \
		-optimize=${OPTIMIZE_FLAG} \
		-library-path+=../OSMF/osmf.swc \
		-output osmfutils.swc -include-sources src 

OSMF/osmf.swc: $(shell find OSMF/ -name \*.as) Makefile
	@echo ============= OSMF ========================
	cd OSMF && ${COMPC} \
		-load-config+=OSMF-build-config.xml \
		-swf-version 20 \
		-debug=${DEBUG_FLAG} \
		-optimize=${OPTIMIZE_FLAG} \
		-output osmf.swc -include-sources . 

clean:
	@echo ============= Cleaning ========================
	rm OSMF/osmf.swc
	rm OSMFUtils/osmfutils.swc
	rm HLSPlugin/hlsPlugin.swc
	rm KalturaHLSPlugin/KalturaHLSPlugin.swf
	rm TestPlayer/html-template/TestPlayer.swf
