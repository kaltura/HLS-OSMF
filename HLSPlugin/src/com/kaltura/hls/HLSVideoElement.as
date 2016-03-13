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
	import org.osmf.traits.DisplayObjectTrait;
	import org.osmf.traits.MediaTraitType;
	import org.osmf.elements.VideoElement;
	import flash.geom.Point;
	import flash.display.Stage;
	import flash.display.Sprite;
	import flash.media.Video;
	import flash.display.DisplayObject;
	import flash.display.DisplayObjectContainer;
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

			if(HLSManifestParser.FORCE_CROP_WORKAROUND_BOTTOM_PERCENT > 0.0)
			{
				cropHackTimer = new Timer(10, 0);
				cropHackTimer.addEventListener(TimerEvent.TIMER, onCropHackTimer);
				cropHackTimer.start();				
			}
		}

		public static var lowerBlocker:Sprite = new Sprite();

		protected function onCropHackTimer(te:TimerEvent):void
		{
			// Sweet hax to adjust the zoom of the stage video.
			var containerDO:DisplayObject = container as DisplayObject;

			var displayObjectTrait:DisplayObjectTrait = getTrait(MediaTraitType.DISPLAY_OBJECT) as DisplayObjectTrait;
			if(displayObjectTrait)
				containerDO = displayObjectTrait.displayObject;

			if(!containerDO)
				return;

			var stage:Stage = containerDO.stage;

			if(stage)
			{
				lowerBlocker.graphics.clear();
				lowerBlocker.graphics.beginFill(0x0); // Useful to debug: 0xff, 0.5);
				lowerBlocker.graphics.drawRect(0, containerDO.height * (1.0 - HLSManifestParser.FORCE_CROP_WORKAROUND_BOTTOM_PERCENT), 
					containerDO.width, containerDO.height * HLSManifestParser.FORCE_CROP_WORKAROUND_BOTTOM_PERCENT);
				(containerDO as DisplayObjectContainer).addChild(lowerBlocker);
			}
		}
	}
}
