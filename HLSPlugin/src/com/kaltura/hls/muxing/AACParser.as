package com.kaltura.hls.muxing 
{
	
	import flash.utils.ByteArray;
	
	import org.osmf.net.httpstreaming.flv.FLVTagAudio;
	
	/**
	 * Extract AAC frames from an Audio Data Transport Stream or ADIF
	 * 
	 * See http://wiki.multimedia.cx/index.php?title=ADTS for details on ADTS, and
	 * http://en.wikipedia.org/wiki/Advanced_Audio_Coding for info on ADIF. 
	 */
	public class AACParser 
	{
		// Possible ADIF syncwords (ie A-D of the format). Baked out for 
		// easier scanning, way simpler as shorts than bit
		// unpacking.
		private static const SYNCWORD1:uint = 0xFFF1;
		private static const SYNCWORD2:uint = 0xFFF9;
		private static const SYNCWORD3:uint = 0xFFF8;
		
		// ADTS/ADIF sample rates lookup table.
		private static const SAMPLE_RATES:Vector.<int> = 
			new<int> [96000, 88200, 64000, 48000, 44100, 32000,
					  24000, 22050, 16000, 12000, 11025, 8000, 7350];
				
		// Helper to determine if some bytes probably have AAC data in them.
		public static function probe(data:ByteArray):Boolean 
		{
			// Extract ID3 header.
			var pos:Number = data.position;
			var id3:ID3Parser = new ID3Parser();
			id3.parse(data);
			
			// If we failed to extract a timestamp, bail.
			if(!id3.hasTimestamp)
			{
				data.position = pos;
				return false;
			}
			
			// Scan a little ways into the buffer looking for an ADTS syncword.
			var searchDistance:Number = Math.min(data.bytesAvailable,256);
			do 
			{
				var potentialSync:uint = data.readUnsignedShort();
				if(potentialSync != SYNCWORD1 
					&& potentialSync != SYNCWORD2 
					&& potentialSync != SYNCWORD3)
					continue;
				
				// It's a match!
				data.position-=2;
				return true;
			}
			while(data.position < searchDistance);
			
			// Clean up and return, no sync.
			data.position = pos;
			return false;
		}
		
		public function parse(data:ByteArray, callback:Function):void 
		{
			// Store output as FLV tags.
			var audioTags:Vector.<FLVTagAudio> = new Vector.<FLVTagAudio>();
			
			// Extract any ID3 header so we can use the timestamp.
			data.position = 0;
			var id3:ID3Parser = new ID3Parser();
			id3.parse(data);
			
			// Parse frames/ADIF data.
			var frameExtents:Vector.<AudioFrameExtents> = getFrameExtents(data, data.position);
			var adifHeader:ByteArray = getADIF(data, 0);

			// Convert everything to FLV tags.
			var curTag:FLVTagAudio;
			var curPTS:Number;
			var tmpBytes:ByteArray = new ByteArray();
			for(var i:int=0; i<frameExtents.length; i++)
			{
				curPTS = Math.round(id3.timestamp+i*1024000 / frameExtents[i].sampleRate);
				
				curTag = new FLVTagAudio();
				curTag.soundFormat = FLVTagAudio.SOUND_FORMAT_AAC;

				if (i != frameExtents.length-1)
					tmpBytes.length = frameExtents[i].length;
				else
					tmpBytes.length = data.length - frameExtents[i].start;
				
				tmpBytes.position = 0;
				tmpBytes.writeBytes(data, frameExtents[i].start, tmpBytes.length);
				curTag.data = tmpBytes;
				
				curTag.timestamp = curPTS;

				audioTags.push(curTag);
			}

			// And issue the callback.
			callback(audioTags, adifHeader);
		}

		// Retrieve ADIF header from ADTS stream.
		public static function getADIF(adts:ByteArray, position:Number=0):ByteArray 
		{
			// Jump to position.
			adts.position = position;

			// Acquire sync.
			var short:uint;
			while((adts.bytesAvailable > 5) 
				&& (short != SYNCWORD1) 
				&& (short != SYNCWORD2)
				&& (short != SYNCWORD3)) 
			{
				short = adts.readUnsignedShort();
			} 
			
			// If we didn't get sync, it's bad.
			if(short != SYNCWORD1
				&& short != SYNCWORD2
				&& short != SYNCWORD3)
			{
				throw new Error("Could not find ADTS syncword.");
				return null;				
			}
				
			// Parse the profile.
			var profile:uint = (adts.readByte() & 0xF0) >> 6;
			if (profile > 3) profile = 5; else profile = 2;
			adts.position--;
			var sampleRateIndex:uint = (adts.readByte() & 0x3C) >> 2;
			adts.position--;
			var numChannels:uint = (adts.readShort() & 0x01C0) >> 6;

			// Emit an ADIF header using the observed data.
			var adifHeader:ByteArray = new ByteArray();
			adifHeader.writeByte((profile << 3) + (sampleRateIndex >> 1));
			adifHeader.writeByte((sampleRateIndex << 7) + (numChannels << 3));
			adifHeader.position = 0;

			// Clean things up and return.
			adts.position -= 4;
			return adifHeader;
		}
		
		// Extract AAC frames from an ADTS.
		public static function getFrameExtents(adts:ByteArray,position:Number=0):Vector.<AudioFrameExtents> 
		{
			var frameStartOffset:uint, frameLength:uint;
			var frames:Vector.<AudioFrameExtents> = new Vector.<AudioFrameExtents>();
			
			// Parse the ID3 tag.
			var id3:ID3Parser = new ID3Parser();
			id3.parse(adts);
			position += id3.lengthInBytes;
			
			// Get raw AAC frames from audio stream.
			adts.position = position;
			var sampleRate:uint;
			
			//Keep 5 bytes available (2 for sync and 4 for length).
			while(adts.bytesAvailable > 5) 
			{
				// Acquire sync.
				var possibleSync:uint = adts.readUnsignedShort();
				if(possibleSync != SYNCWORD1 && possibleSync != SYNCWORD2 && possibleSync != SYNCWORD3)
				{
					// Step forward only one byte and keep looking.
					adts.position -= 1;
					continue;
				}
				
				// If we don't know the sample rate, peek it.
				if(!sampleRate) 
				{
					sampleRate = SAMPLE_RATES[(adts.readByte() & 0x3C) >> 2];
					adts.position--;
				}
				
				// Store raw AAC preceding this header.
				if(frameStartOffset)
					frames.push(new AudioFrameExtents(frameStartOffset, frameLength, sampleRate));

				// Syncwords predicate slightly different behavior.
				if(possibleSync == SYNCWORD3) 
				{
					frameLength = ((adts.readUnsignedInt() & 0x0003FFE0) >> 5) - 9;
					frameStartOffset = adts.position + 3;
					adts.position += frameLength + 3;
				} 
				else 
				{
					frameLength = ((adts.readUnsignedInt() & 0x0003FFE0) >> 5) - 7;
					frameStartOffset = adts.position + 1;
					adts.position += frameLength + 1;
				}
			}
			
			// Don't forget trailing data.
			if(frameStartOffset) 
				frames.push(new AudioFrameExtents(frameStartOffset, frameLength, sampleRate));

			// Reset position.
			adts.position = position;

			// And return extracted frames.
			return frames;
		}
	}
}

// Used to keep track of regions that we are reading/writing bytes from.
final class AudioFrameExtents 
{
	public var start:uint;
	public var length:uint;
	public var sampleRate:uint;
	
	public function AudioFrameExtents(_start:uint, _length:uint, _sampleRate:uint) 
	{
		start      = _start;
		length     = _length;
		sampleRate = _sampleRate;
	}
}
