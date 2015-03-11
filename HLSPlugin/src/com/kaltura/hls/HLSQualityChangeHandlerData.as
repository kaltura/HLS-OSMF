package com.kaltura.hls
{
	public class HLSQualityChangeHandlerData
	{
		// A loose collection of start times associated with a specific uri, elements will be
		// removed from this object as they moved to the latestKnownTimes vector
		public var startTimeWitnesses:Object = {};
		
		// A collection of the latest known times for each quality level, organized by quality level.
		// Each object contains to elements, a 'uri' and 'time;
		private var lastestKnownTimes:Vector.<Object>;
		
		/**** Non-property accessors ****/
		
		// Takes a quality, uri, and time and adds it to the lastestKnownTime vector (overriding the previous item)
		public function setLastestKnownTimes(quality:int, uri:String, time:Number):void
		{
			lastestKnownTimes[quality] = { "uri": uri, "time": time };
			
			// Remove the uri from the startTimeWitnesses if it exists
			if (startTimeWitnesses.hasOwnProperty(uri)) delete startTimeWitnesses[uri];
		}
		
		// Attempts to find a time with the uri and quality level provided. If no time can be found then
		// 0 is returned
		public function findLatestTime(quality:int, uri:String):Object
		{
			return lastestKnownTimes[quality].hasOwnProperty(uri) ? lastestKnownTimes[quality][uri] : 0;
		}
	}
}