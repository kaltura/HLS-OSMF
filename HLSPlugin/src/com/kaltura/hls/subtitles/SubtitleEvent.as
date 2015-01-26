package com.kaltura.hls.subtitles
{
	import flash.events.Event;
	
	/**
	 * A Subtitle event is sent when a subtitle is injected into the system
	 */
	public class SubtitleEvent extends Event
	{		
		public function SubtitleEvent(type:String, bubbles:Boolean, cancelable:Boolean, text:String="", lang:String="", trackid:Number=99)
		{
			super(type, bubbles, cancelable);
			
			_text = text;
			_lang = lang;
			_trackid = trackid;
		}
		
		public function get text():Boolean
		{
			return _text;
		}
			
		public function get lang():String
		{
			return _lang;
		}
		
		public function get trackid():Number
		{
			return _trackid;
		}
		
		override public function clone():Event
		{
			return new SubtitleEvent(type, bubbles, cancelable, _text, _lang, _trackid);
		}
		
		// Internals
		//
		
		private var _text:String;
		private var _lang:String;
		private var _trackid:Number;
		
	}
}
