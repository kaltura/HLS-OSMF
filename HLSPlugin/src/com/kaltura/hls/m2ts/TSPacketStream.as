package com.kaltura.hls.m2ts
{
    import flash.utils.ByteArray;
    import flash.net.ObjectEncoding;
    import flash.utils.ByteArray;
    import flash.utils.Endian;    
    import flash.utils.IDataInput;
    import flash.utils.IDataOutput;

    /**
     * Packetized ES stream parser state.
     */
    public class TSPacketStream
    {
        public var buffer:ByteArray = new ByteArray();
        public var lastContinuity:int;
        public var packetID:int;

        public var finishedLast:Boolean = false;

        /**
         * Return length if it can be safely determined.
         */
        public function get packetLength():int
        {
            if(buffer.length < 6)
                return 0;

            return ((buffer[4] << 8) + buffer[5]);
        }
    }
}