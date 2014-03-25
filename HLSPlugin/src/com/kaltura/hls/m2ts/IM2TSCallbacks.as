package com.kaltura.hls.m2ts
{
	import flash.utils.ByteArray;
	
	/**
	 * Callbacks from the M2TSParser; one for each type of frame found in a TS.
	 */
	public interface IM2TSCallbacks
	{
		function onMP3Packet(pts:Number, dts:Number, bytes:ByteArray, cursor:uint, length:uint):void;
		function onAACPacket(pts:Number, bytes:ByteArray, cursor:uint, length:uint):void;
		function onAVCNALU(pts:Number, dts:Number, bytes:ByteArray, cursor:uint, length:uint):void;
		function onAVCNALUFlush(pts:Number, dts:Number):void;
		function onOtherElementaryPacket(packetID:uint, type:uint, pts:Number, dts:Number, cursor:uint, bytes:ByteArray):void;
		function onOtherPacket(packetID:uint, bytes:ByteArray):void;
	}
}