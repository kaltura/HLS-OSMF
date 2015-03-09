package com.kaltura.hls.m2ts
{
    import flash.utils.ByteArray;
    import flash.net.ObjectEncoding;
    import flash.utils.ByteArray;
    import flash.utils.Endian;    
    import flash.utils.IDataInput;
    import flash.utils.IDataOutput;

    /**
     * Helper for processing PES streams.
     */
    public class PESPacketStream
    {
        public function PESPacketStream()
        {
            buffer = new ByteArray();
            _shiftBuffer = new ByteArray();
        }

        public function append(bytes:ByteArray, cursor:int):void
        {
            buffer.position = buffer.length;
            buffer.writeBytes(bytes, cursor, bytes.length - cursor);
        }
        
        /**
         * Drop bytes from the left of the PES packet stream buffer.
         */
        public function shiftLeft(num:int):void
        {
            var newLength:int = buffer.length - num;
            var tmpBytes:ByteArray;
            
            _shiftBuffer.length = newLength;
            _shiftBuffer.position = 0;
            _shiftBuffer.writeBytes(buffer, num, newLength);
            
            tmpBytes = buffer;
            buffer = _shiftBuffer;
            _shiftBuffer = tmpBytes;
        }
        
        public var buffer:ByteArray;
        public var pts:Number;
        public var dts:Number;
        
        // We swap back and forth to avoid allocations.
        private var _shiftBuffer:ByteArray;
    }
}