package com.kaltura.hls.m2ts
{
	/**
	 * Assorted constants relating to the FLV format.
	 */
	public class FLVTags
	{
		public static const HEADER_LENGTH:int = 11;
		public static const HEADER_VIDEO_FLAG:int = 0x01;
		public static const HEADER_AUDIO_FLAG:int = 0x04;
		public static const PREVIOUS_LENGTH_LENGTH:int = 4;
		
		public static const TYPE_AUDIO:int = 0x08;
		public static const TYPE_VIDEO:int = 0x09;
		public static const TYPE_SCRIPTDATA:int = 0x12;
		
		public static const AUDIO_CODEC_MP3:int = 0x2f;
		public static const AUDIO_CODEC_AAC:int = 0xaf;
		
		public static const VIDEO_CODEC_AVC_KEYFRAME:int = 0x17;
		public static const VIDEO_CODEC_AVC_PREDICTIVEFRAME:int = 0x27;
		
		public static const AVC_MODE_AVCC:int = 0x00;
		public static const AVC_MODE_PICTURE:int = 0x01;
		
		public static const AAC_MODE_CONFIG:int = 0x00;
		public static const AAC_MODE_FRAME:int = 0x01;
		
		public static const ADTS_FRAME_HEADER_LENGTH:uint = 7;
	}
}