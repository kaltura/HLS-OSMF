/*****************************************************
*  
*  Copyright 2009 Adobe Systems Incorporated.  All Rights Reserved.
*  
*****************************************************
*  The contents of this file are subject to the Mozilla Public License
*  Version 1.1 (the "License"); you may not use this file except in
*  compliance with the License. You may obtain a copy of the License at
*  http://www.mozilla.org/MPL/
*   
*  Software distributed under the License is distributed on an "AS IS"
*  basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
*  License for the specific language governing rights and limitations
*  under the License.
*   
*  
*  The Initial Developer of the Original Code is Adobe Systems Incorporated.
*  Portions created by Adobe Systems Incorporated are Copyright (C) 2009 Adobe Systems 
*  Incorporated. All Rights Reserved. 
*  
*****************************************************/
package com.kaltura.hls
{
	import __AS3__.vec.Vector;
	
	import org.osmf.media.MediaResourceBase;
	import org.osmf.net.NetLoader;
	import org.osmf.net.rtmpstreaming.RTMPDynamicStreamingNetLoader;
	import org.osmf.traits.LoaderBase;
	import org.osmf.elements.VideoElement;
	import flash.geom.Point;
	import flash.display.Stage;
	import flash.display.DisplayObject;
	import flash.utils.Timer;
    import flash.events.TimerEvent;
    import com.kaltura.hls.manifest.HLSManifestParser;

	CONFIG::FLASH_10_1
	{
	import flash.events.DRMAuthenticateEvent;
	import flash.events.DRMErrorEvent;
	import flash.events.DRMStatusEvent;
	import flash.net.drm.DRMContentData;	
	import flash.system.SystemUpdaterType;
	import flash.system.SystemUpdater;	
	import org.osmf.net.drm.NetStreamDRMTrait;
	import org.osmf.net.httpstreaming.HTTPStreamingNetLoader;
	}
	
	public class HLSVideoElement extends VideoElement
	{
		public var cropHackTimer:Timer;

		public function HLSVideoElement(resource:MediaResourceBase=null, loader:NetLoader=null)
		{
			super(resource, loader);

			cropHackTimer = new Timer(250, 0);
			cropHackTimer.addEventListener(TimerEvent.TIMER, onCropHackTimer);
			cropHackTimer.start();
		}

		protected function onCropHackTimer(te:TimerEvent):void
		{
			// Sweet hax to adjust the zoom of the stage video.
			var containerDO:DisplayObject = container as DisplayObject;
			if(!containerDO)
				return;

			var stage:Stage = containerDO.stage;
			if(stage.stageVideos.length > 0)
			{
				stage.stageVideos[0].zoom = new Point(HLSManifestParser.FORCE_CROP_WORKAROUND_ZOOM_X, HLSManifestParser.FORCE_CROP_WORKAROUND_ZOOM_Y);
				stage.stageVideos[0].pan = new Point(HLSManifestParser.FORCE_CROP_WORKAROUND_PAN_X, HLSManifestParser.FORCE_CROP_WORKAROUND_PAN_Y);
			}
			else
			{
				containerDO.scaleX = HLSManifestParser.FORCE_CROP_WORKAROUND_ZOOM_X;
				containerDO.scaleY = HLSManifestParser.FORCE_CROP_WORKAROUND_ZOOM_Y;
				containerDO.x = HLSManifestParser.FORCE_CROP_WORKAROUND_PAN_X * containerDO.width;
				containerDO.x = HLSManifestParser.FORCE_CROP_WORKAROUND_PAN_Y * containerDO.height;
			}
		}

	    /**
	     * @private
		 */
		override protected function processReadyState():void
		{
			super.processReadyState();
		}		
	}
}
