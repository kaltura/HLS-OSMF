# Simple makefile to allow command line compilation.
#
# Only tested on OSX but the principle should work everywhere.

# Set these to your paths.
MXMLC="/Applications/Adobe Flash Builder 4.7/sdks/4.6.0/bin/mxmlc"
COMPC="/Applications/Adobe Flash Builder 4.7/sdks/4.6.0/bin/compc"
flexlib="/Applications/Adobe Flash Builder 4.7/sdks/4.6.0/"


# First time, run make disabled all
# Then only need to run disable if you change OSMF or OSMFUtils
all:
	@echo ============= OSMF ========================
	cd OSMF && ${COMPC} \
		-load-config+=OSMF-build-config.xml \
		-swf-version 20 \
		-debug=true \
		-output osmf.swc -include-sources . 
	@echo ============= OSMFUtils ========================
	cd OSMFUtils && ${COMPC} \
		-load-config+=OSMFUtils-build-config.xml \
		-swf-version 20 \
		-debug=true \
		-library-path+=../OSMF/osmf.swc \
		-output osmfutils.swc -include-sources src 
	@echo ============= HLSPlugin ========================
	cd HLSPlugin && ${COMPC} \
		-load-config+=HLS-build-config.xml \
		-library-path+=../OSMF/osmf.swc \
		-library-path+=libs/aes-decrypt.swc \
		-swf-version 20 \
		-use-network=true \
		-debug=true \
		-output hlsPlugin.swc -include-sources src
#		-debug=true \
	@echo ============ TestPlayer ========================
	cd TestPlayer && ${MXMLC} \
		-static-link-runtime-shared-libraries=true \
		-library-path+=../OSMF/osmf.swc \
		-library-path+=../OSMFUTils/osmfutils.swc \
		-library-path+=../HLSPlugin/libs/aes-decrypt.swc \
		-library-path+=../hlsPlugin/hlsPlugin.swc \
		-swf-version 20 \
		-use-network=true \
		-debug=true \
		-output html-template/TestPlayer.swf -source-path+=src src/DashTest.mxml
		#-debug=true \


