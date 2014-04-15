package com.kaltura.hls.manifest
{
	import com.hurlant.util.Hex;
	import com.kaltura.crypto.DecryptUtil.CModule;
	import com.kaltura.crypto.DecryptUtil.decryptAES;
	
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.net.URLLoader;
	import flash.net.URLLoaderDataFormat;
	import flash.net.URLRequest;
	import flash.utils.ByteArray;
	import flash.utils.Dictionary;
	import flash.utils.getTimer;

	/**
	 * HLSManifestEncryptionKey is used to parse AES decryption key data from a m3u8
	 * manifest, load the specified key file into memory, and use the key data to decrypt
	 * audio and video streams. It supports AES-128 encryption with #PKCS7 padding, as well
	 * as explicitly set Initialization Vectors. If an Initialization Vector is not provided,
	 * the segment id of the stream to be decrypted will be used.
	 */
	
	public class HLSManifestEncryptionKey extends EventDispatcher
	{
		private static const LOADER_CACHE:Dictionary = new Dictionary();
		private static const IV_DATA_CACHE:ByteArray = new ByteArray();
		
		public var usePadding:Boolean = false;
		public var iv:String = "";
		public var url:String = "";
		
		// Keep track of the segments this key applies to
		public var startSegmentId:uint = 0;
		public var endSegmentId:uint = uint.MAX_VALUE;
		
		private var _keyData:ByteArray;
		private var _explicitIVData:ByteArray;
		
		private static var _decryptInitialized:Boolean = false;
		
		public function HLSManifestEncryptionKey()
		{
			if ( !_decryptInitialized )
			{
				CModule.startAsync();
				_decryptInitialized = true;
			}
		}
		
		public function get isLoaded():Boolean { return _keyData != null; }
		
		public static function fromParams( params:String ):HLSManifestEncryptionKey
		{
			var result:HLSManifestEncryptionKey = new HLSManifestEncryptionKey();
			
			var tokens:Array = params.split( ',' );
			var tokenCount:int = tokens.length;
			for ( var i:int = 0; i < tokenCount; i++ )
			{
				var tokenSplit:Array = tokens[ i ].split( '=' );
				var name:String = tokenSplit[ 0 ];
				var value:String = tokenSplit[ 1 ];
				
				switch ( name )
				{
					case "URI" :
						result.url = value;
						// Uncomment the line below to use a local key for debugging instead,
						// requires file to exist
						// result.url = "http://localhost:5000/video.key";
						break;
					
					case "IV" :
						result.iv = value;
						break;
				}
				
			}
			
			return result;
		}
		
		public static function clearLoaderCache():void
		{
			for ( var key:String in LOADER_CACHE ) delete LOADER_CACHE[ key ];
		}
		
		/**
		 * Decrypts a video or audio stream using AES-128. If an Initialization Vector was not provided
		 * during key creation, the passed in segment id of the video will be converted to
		 * a 32 Byte ByteArray and used as the IV.
		 * 
		 * Note: Segment IDs passed in cannot exceed 2^32
		 */
		
		public function decrypt( data:ByteArray, segmentId:uint = 0 ):void
		{
			var startTime:uint = getTimer();
			
			if ( iv == "" )
			{
				// No IV exists, set it to segment id
				setIVDataCacheTo( segmentId );
				decryptAES( data, _keyData, IV_DATA_CACHE, usePadding );
			}
			else decryptAES( data, _keyData, _explicitIVData, usePadding );
			
			trace( "DECRYPTION OF " + data.length + " BYTES TOOK " + ( getTimer() - startTime ) + " MS" );
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
			if ( isLoaded ) throw new Error( "Already loaded!" );
			var loader:URLLoader = getLoader( url );
			if ( loader.bytesTotal > 0 && loader.bytesLoaded == loader.bytesTotal ) onLoad();
			else loader.addEventListener( Event.COMPLETE, onLoad );
		}
		
		private function onLoad( e:Event = null ):void
		{
			var loader:URLLoader = getLoader( url );
			
			_keyData = loader.data as ByteArray;
			
			if ( iv )
			{
				var ivData:ByteArray = Hex.toArray( iv ); 
				_explicitIVData = ivData;
			}
			
			loader.removeEventListener( Event.COMPLETE, onLoad );
			dispatchEvent( new Event( Event.COMPLETE ) );
		}
		
		private static function setIVDataCacheTo( value:uint ):void
		{
			IV_DATA_CACHE.position = 0;
			IV_DATA_CACHE.writeUnsignedInt( 0 );
			IV_DATA_CACHE.writeUnsignedInt( 0 );
			IV_DATA_CACHE.writeUnsignedInt( 0 );
			IV_DATA_CACHE.writeUnsignedInt( value );
		}
	}
}