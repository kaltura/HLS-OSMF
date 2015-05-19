package com.kaltura.hls.m2ts
{
    import com.kaltura.hls.muxing.AACParser;
    
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
        public function PESPacket(id:int, bytes:ByteArray	)
        {
            packetID = id;
            buffer = bytes;
        }

        public function clone():PESPacket
        {
            var tmpBuffer:ByteArray = new ByteArray();
            tmpBuffer.writeBytes(buffer);

            var p:PESPacket = new PESPacket(packetID, tmpBuffer);
            p.pts = pts;
            p.dts = dts;
            p.type = type;
            return p;
        }

        public var type:int = -1;

        public var pts:Number, dts:Number;
        public var packetID:int = -1;
        public var buffer:ByteArray = null;
    }
}