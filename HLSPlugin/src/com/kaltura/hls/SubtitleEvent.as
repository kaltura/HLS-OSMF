package com.kaltura.hls
{
	import flash.events.*;
	
	/**
	 * An event describing subtitle text. Fired from the SubtitleTrait.
	 */
	public class SubtitleEvent extends Event
	{
		public static const CUE:String = "cue";
		
		public var startTime:Number;
		public var text:String;
		public var language:String;

		public function SubtitleEvent(_startTime:Number, _text:String, _language:String)
		{
			super(CUE);

			startTime = _startTime;
			text = _text;
			language = _language;
		}
	
}}