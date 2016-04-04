package com.kaltura.hls.manifest
{
	import com.hurlant.util.Hex;
	import com.kaltura.hls.crypto.FastAESKey;
	
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.net.URLLoader;
	import flash.net.URLLoaderDataFormat;
	import flash.net.URLRequest;
	import flash.utils.ByteArray;
	import flash.utils.Dictionary;
	import flash.utils.getTimer;

	CONFIG::LOGGING
	{
		import org.osmf.logging.Logger;
        import org.osmf.logging.Log;
	}

	/**
	 * HLSManifestEncryptionKey is used to parse AES decryption key data from a m3u8
	 * manifest, load the specified key file into memory, and use the key data to decrypt
	 * audio and video streams. It supports AES-128 encryption with #PKCS7 padding, and uses
	 * explicitly passed in Initialization Vectors.
	 */
	
	public class HLSManifestEncryptionKey extends EventDispatcher
	{
        CONFIG::LOGGING
        {
            private static const logger:Logger = Log.getLogger("com.kaltura.hls.manifest.HLSManifestEncryptionKey");
        }

		private static const LOADER_CACHE:Dictionary = new Dictionary();
		private var _key:FastAESKey;
		public var usePadding:Boolean = false;
		public var iv:String = "";
		public var url:String = "";
		private var iv0 : uint;
		private var iv1 : uint;
		private var iv2 : uint;
		private var iv3 : uint;
		
		// Keep track of the segments this key applies to
		public var startSegmentId:uint = 0;
		public var endSegmentId:uint = uint.MAX_VALUE;
		
		private var _keyData:ByteArray;

		public var isLoading:Boolean = false;
		
		public function HLSManifestEncryptionKey()
		{
			
		}
		
		public function get isLoaded():Boolean { return _keyData != null; }

		public override function toString():String
		{
			return "[HLSManifestEncryptionKey start=" + startSegmentId +", end=" + endSegmentId + ", iv=" + iv + ", url=" + url + ", loaded=" + isLoaded + "]";
		}
		
		public static function fromParams( params:String ):HLSManifestEncryptionKey
		{
			var result:HLSManifestEncryptionKey = new HLSManifestEncryptionKey();
			
			var tokens:Array = KeyParamParser.parseParams( params );
			var tokenCount:int = tokens.length;
			
			for ( var i:int = 0; i < tokenCount; i += 2 )
			{
				var name:String = tokens[ i ];
				var value:String = tokens[ i + 1 ];
				
				switch ( name )
				{
					case "URI" :
						result.url = value;
						break;
					
					case "IV" :
						result.iv = value;
						break;
				}
				
			}
			
			return result;
		}
		
		/**
		 * Creates an initialization vector from the passed in uint ID, usually
		 * a segment ID.
		 */
		public static function createIVFromID( id:uint ):ByteArray
		{
			var result:ByteArray = new ByteArray();
			result.writeUnsignedInt( 0 );
			result.writeUnsignedInt( 0 );
			result.writeUnsignedInt( 0 );
			result.writeUnsignedInt( id );
			return result;
		}
		
		public static function clearLoaderCache():void
		{
			for ( var key:String in LOADER_CACHE ) delete LOADER_CACHE[ key ];
		}
		
		/**
		 * Decrypts a video or audio stream using AES-128 with the provided initialization vector.
		 */
		
		public function decrypt( data:ByteArray, iv:ByteArray ):ByteArray
		{
			//logger.debug("got " + data.length + " bytes");
			if(data.length == 0)
				return data;
				
			var startTime:uint = getTimer();
			_key = new FastAESKey(_keyData);
			iv.position = 0;
			iv0 = iv.readUnsignedInt();
			iv1 = iv.readUnsignedInt();
			iv2 = iv.readUnsignedInt();
			iv3 = iv.readUnsignedInt();
			data.position = 0;
			data = _decryptCBC(data,data.length);
			if ( usePadding ){
				data = unpad( data );
			}
		//	logger.debug( "DECRYPTION OF " + data.length + " BYTES TOOK " + ( getTimer() - startTime ) + " MS" );
			return data;
		}
		
		
		/* Cypher Block Chaining Decryption, refer to
		* http://en.wikipedia.org/wiki/Block_cipher_mode_of_operation#Cipher-block_chaining_
		* for algorithm description
		*/
		private function _decryptCBC(crypt : ByteArray, len : uint) : ByteArray {
			var src : Vector.<uint> = new Vector.<uint>(4);
			var dst : Vector.<uint> = new Vector.<uint>(4);
			var decrypt : ByteArray = new ByteArray();
			decrypt.length = len;
			
			for (var i : uint = 0; i < len / 16; i++) {
				// read src byte array
				src[0] = crypt.readUnsignedInt();
				src[1] = crypt.readUnsignedInt();
				src[2] = crypt.readUnsignedInt();
				src[3] = crypt.readUnsignedInt();
				
				// AES decrypt src vector into dst vector
				_key.decrypt128(src, dst);
				
				// CBC : write output = XOR(decrypted,IV)
				decrypt.writeUnsignedInt(dst[0] ^ iv0);
				decrypt.writeUnsignedInt(dst[1] ^ iv1);
				decrypt.writeUnsignedInt(dst[2] ^ iv2);
				decrypt.writeUnsignedInt(dst[3] ^ iv3);
				
				// CBC : next IV = (input)
				iv0 = src[0];
				iv1 = src[1];
				iv2 = src[2];
				iv3 = src[3];
			}
			return decrypt;
		}
		public function unpad(bytesToUnpad : ByteArray) : ByteArray {
			if ((bytesToUnpad.length % 16) != 0)
			{
				throw new Error("PKCS#5::unpad: ByteArray.length isn't a multiple of the blockSize");
				return a;
			}

			const paddingValue:int = bytesToUnpad[bytesToUnpad.length - 1];
			if (paddingValue > 15)
			{
				return bytesToUnpad;
			}
			var doUnpad:Boolean = true;
			for (var i:int = 0; i<paddingValue; i++) {
				var readValue:int = bytesToUnpad[bytesToUnpad.length - (1 + i)];
				if (paddingValue != readValue) 
				{
					//throw new Error("PKCS#5:unpad: Invalid padding value. expected [" + paddingValue + "], found [" + readValue + "]");
					//break;
					doUnpad = false;
					//Break to make sure we don't underrun the byte array with a byte value bigger than 16
					break;
				}
			}

			if(doUnpad)
			{
				//subtract paddingValue + 1 since the value is one less than the number of padded bytes
				bytesToUnpad.length -= paddingValue + 1;
			}

			return bytesToUnpad;
		}

		public function retrieveStoredIV():ByteArray
		{
			CONFIG::LOGGING
			{
				logger.debug("IV of " + iv + " for " + url + ", key=" + Hex.fromArray(_keyData));
			}
			return Hex.toArray( iv );
		}
		
		private static function getLoader( url:String ):URLLoader
		{
			if ( LOADER_CACHE[ url ] != null ) return LOADER_CACHE[ url ] as URLLoader;
			var newLoader:URLLoader = new URLLoader();
			newLoader.dataFormat = URLLoaderDataFormat.BINARY;
			newLoader.load( new URLRequest( url ) );
			LOADER_CACHE[ url ] = newLoader;
			return newLoader;
		}
		
		public function load():void
		{
			isLoading = true;

			if ( isLoaded ) throw new Error( "Already loaded!" );
			var loader:URLLoader = getLoader( url );
			if ( loader.bytesTotal > 0 && loader.bytesLoaded == loader.bytesTotal ) onLoad();
			else loader.addEventListener( Event.COMPLETE, onLoad );
		}
		
		private function onLoad( e:Event = null ):void
		{
			isLoading = false;

			CONFIG::LOGGING
			{
				logger.debug("KEY LOADED! " + url);
			}

			var loader:URLLoader = getLoader( url );
			_keyData = loader.data as ByteArray;
			loader.removeEventListener( Event.COMPLETE, onLoad );
			dispatchEvent( new Event( Event.COMPLETE ) );
		}
	}
}

class KeyParamParser
{
	private static const STATE_PARSE_NAME:String = "ParseName";
	private static const STATE_BEGIN_PARSE_VALUE:String = "BeginParseValue";
	private static const STATE_PARSE_VALUE:String = "ParseValue";
	
	public static function parseParams( paramString:String ):Array
	{
		var result:Array = [];
		var cursor:int = 0;
		var state:String = STATE_PARSE_NAME;
		var accum:String = "";
		var usingQuotes:Boolean = false;
		
		while ( cursor < paramString.length )
		{
			var char:String = paramString.charAt( cursor );
			switch ( state )
			{
				case STATE_PARSE_NAME:
					
					if ( char == '=' )
					{
						result.push( accum );
						accum = "";
						state = STATE_BEGIN_PARSE_VALUE;
					}
					else accum += char;
					break;
				
				case STATE_BEGIN_PARSE_VALUE:
					
					if ( char == '"' ) usingQuotes = true;
					else accum += char;
					state = STATE_PARSE_VALUE;
					break;
				
				case STATE_PARSE_VALUE:
					
					if ( !usingQuotes && char == ',' )
					{
						result.push( accum );
						accum = "";
						state = STATE_PARSE_NAME;
						break;
					}
					
					if ( usingQuotes && char == '"' )
					{
						usingQuotes = false;
						break;
					}
					
					accum += char;
					break;
			}
			
			cursor++;
			
			if ( cursor == paramString.length ) result.push( accum );
		}
		
		return result;
	}
}
