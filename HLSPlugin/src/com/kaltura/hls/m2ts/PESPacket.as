package com.kaltura.hls.m2ts
{
    import flash.utils.ByteArray;
    import flash.net.ObjectEncoding;
    import flash.utils.ByteArray;
    import flash.utils.Endian;    
    import flash.utils.IDataInput;
    import flash.utils.IDataOutput;

    /**
     * An packetized elementary stream recovered from the TS.
     */
    public class PESPacket
    {
        public function PESPacket(id:int, bytes:ByteArray)
        {
            packetID = id;
            buffer = bytes;
        }

        public var pts:Number, dts:Number;
        public var packetID:int = -1;
        public var buffer:ByteArray = null;
    }
}