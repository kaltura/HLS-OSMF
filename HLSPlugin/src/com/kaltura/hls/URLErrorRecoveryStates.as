package com.kaltura.hls
{
	/**
	 * This simple class holds state enumerations for URL error recovery
	 */
	public final class URLErrorRecoveryStates
	{
		public static const IDLE:int = 0;
		public static const SEG_BY_TIME_ATTEMPTED:int = 1;
		public static const NEXT_SEG_ATTEMPTED:int = 2;
	}
}