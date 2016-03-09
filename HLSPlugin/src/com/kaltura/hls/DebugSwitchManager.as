/*****************************************************
 *  
 *  Copyright 2011 Adobe Systems Incorporated.  All Rights Reserved.
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
 *  Portions created by Adobe Systems Incorporated are Copyright (C) 2011 Adobe Systems 
 *  Incorporated. All Rights Reserved. 
 *  
 *****************************************************/
package com.kaltura.hls
{
	import flash.errors.IllegalOperationError;
	import flash.events.EventDispatcher;
	
	import org.osmf.events.HTTPStreamingEvent;
	import org.osmf.net.metrics.MetricRepository;
	import org.osmf.net.rules.Recommendation;
	import org.osmf.net.rules.RuleBase;
	import org.osmf.utils.OSMFStrings;
	import org.osmf.net.RuleSwitchManagerBase;
	import org.osmf.net.NetStreamSwitcher;
	import org.osmf.net.qos.*;

	CONFIG::LOGGING
	{
		import org.osmf.logging.Logger;
		import org.osmf.logging.Log;
	}
	
	/**
	 * Debug switch manager - returns a preprogrammed set of bitrate selections
	 * to simplify debugging bitrate transition issues. The first bitrate selected
	 * is driven by HLSLoader and not gotten via the switch manager.
	 */
	public class DebugSwitchManager extends RuleSwitchManagerBase
	{

		public function DebugSwitchManager
			( notifier:EventDispatcher
			, switcher:NetStreamSwitcher
			, metricRepository:MetricRepository
			, emergencyRules:Vector.<RuleBase> = null
			, autoSwitch:Boolean = true
			)
		{
			super(notifier, switcher, metricRepository, emergencyRules, autoSwitch);
		}
		
		/**
		 * Set of bitrate indices to choose, in order, to simulate desired behavior.
		 */
		public static var SWITCH_SEQUENCE:Array = [0,1,0,1,0,1];

		public var currentSequenceIndex:int = 0;

		public override function getNewIndex():uint
		{
			var nextValue:int = SWITCH_SEQUENCE[currentSequenceIndex % SWITCH_SEQUENCE.length];
			currentSequenceIndex++;
			CONFIG::LOGGING
			{
				logger.debug("Getting next bitrate from sequence: " + nextValue + ", offset=" + currentSequenceIndex + ", sequence=" + SWITCH_SEQUENCE.join(","));
			}
			return nextValue;
		}
		
		public override function getNewEmergencyIndex(maxBitrate:Number):uint
		{
			CONFIG::LOGGING
			{
				logger.debug("Getting next bitrate (EMERGENCY)");
			}
			return getNewIndex();
		}
		
		CONFIG::LOGGING
		{
			private static const logger:Logger = Log.getLogger("com.kaltura.hls.DebugSwitchManager");
		}
	}
}