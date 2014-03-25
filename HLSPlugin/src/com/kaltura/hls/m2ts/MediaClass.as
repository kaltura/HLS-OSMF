package com.kaltura.hls.m2ts
{
	/**
	 * Constants for media class in an M2TS.
	 */
	public class MediaClass
	{
		static public const OTHER:int = 0;
		static public const VIDEO:int = 1;
		static public const AUDIO:int = 2;
		
		static public function calculate(type:int):int
		{
			switch(type)
			{
				case 0x03: // ISO 11172-3 MP3 audio
				case 0x04: // ISO 13818-3 MP3-betterness audio
				case 0x0f: // AAC audio in ADTS transport syntax
					return AUDIO;
					
				case 0x1b: // H.264/MPEG-4 AVC
					return VIDEO;
					
				default:
					return OTHER;
			}
		}
	}
}