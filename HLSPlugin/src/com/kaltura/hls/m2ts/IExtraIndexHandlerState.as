package com.kaltura.hls.m2ts
{
	/**
	 * We require a little bit of extra information from the index handler to support
	 * ads and other advanced streaming behavior.
	 */
	public interface IExtraIndexHandlerState
	{		
		function getCurrentContinuityToken():String;
		
		function calculateFileOffsetForTime(time:Number):Number;

		function getCurrentSegmentOffset():Number;

		function getCurrentSegmentEnd():Number;

		function getTargetSegmentDuration():Number;
	}
}