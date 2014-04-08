Building the Kaltura HLS Plugin
===============================

To build the Kaltura HLS plugin, import the following projects into your workspace in FlashBuilder 4.6. The recommended version of the Flex SDK is 4.5.1.

   * hlsPlugin - This is the SWC.
   * KalturaHLSPlugin - This packages the SWC into a loadable OSMF SWF plugin.
   * OSMF - the version of OSMF that the plugin uses.
   * OSMFUtils - Some utilties for TestPlayer.
   * TestPlayer - A rudimentary test player provided by Digital Primates.

Set Library Path Dependencies for each of the projects:

    hlsPlugin depends on...
		OSMF project
	KalturaHLSPlugin depends on...
		hlsPlugin project
	OSMFUtils depends on...
		OSMF project
	TestPlayer depends on...
		OSMF project
		OSMFUtils project
		
Project References for each of the projects:

	hlsPlugin
		OSMF
	KalturaHLSPlugin
		hlsPlugin
		OSMF
	OSMFUtils
		OSMF
	TestPlayer
		OSMF
		OSMFUtils

Build them all to get the KalturaHLSPlugin.swf from the 
KalturaHLSPlugin/bin-debug folder. This may then be loaded in the Kaltura Player (or any OSMF-based player).

**Note:** You have to make sure that you set the project references correctly or OSMF won't be bundled with the SWF, and errors will occur due to incompatible versions.

