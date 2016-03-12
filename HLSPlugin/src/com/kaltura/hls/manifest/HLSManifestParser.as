package com.kaltura.hls.manifest
{
	import com.kaltura.hls.subtitles.SubTitleParser;
	
	import flash.external.ExternalInterface;
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.events.IOErrorEvent;
	import flash.events.SecurityErrorEvent;
	import flash.external.ExternalInterface;
	import com.adobe.serialization.json.JSON;
	import flash.net.URLLoader;
	import flash.net.URLRequest;
	import flash.utils.getTimer;
	
	CONFIG::LOGGING
	{
		import org.osmf.logging.Logger;
        import org.osmf.logging.Log;
	}

	/**
	 *  Fires Event.COMPLETE when the manifest is fully loaded. 
	 */
	public class HLSManifestParser extends EventDispatcher
	{
        CONFIG::LOGGING
        {
            private static const logger:Logger = Log.getLogger("com.kaltura.hls.manifest.HLSManifestParser");
        }

		public static const DEFAULT:String = "DEFAULT";
		public static const AUDIO:String = "AUDIO";
		public static const VIDEO:String = "VIDEO";
		public static const SUBTITLES:String = "SUBTITLES";
		
		/**
		 * When true, we cease issuing any manifest requests. This can be used
		 * to suppress manifest reloads while a stream is down.
		 */
		public static var STREAM_DEAD:Boolean = false;

		/**
		 * When true, we issue JS callbacks to an HTML5 debug visualizer.
		 */
		public static var SEND_LOGS:Boolean = false;

		/**
		 * When true, we seek to live edge when we experience a buffering event.
		 *
		 * Seeking will occur if we are buffering for longer than 1.5x target
		 * duration of the current manifest.
		 */
		public static var ALWAYS_SEEK_TO_LIVE_EDGE_ON_BUFFER:Boolean = false;

		/**
		 * Keep this many segments back from the live edge in DVR/Live streams.
		 *
		 * Note that if the buffer threshold is LONGER than this, you will have 
		 * very long buffering when starting live streams. 
		 *
		 * Here is an example: Imagine segments are 10 seconds long.
		 * NORMAL_BUFFER_THRESHOLD is set to 30. MAX_SEG_BUFFER is set to 2. The
		 * player will start downloading 2 segments from the end and download 20
		 * seconds of video immediately. However there will not be enough to begin
		 * playback (30 seconds are required). As a result, playback will not start
		 * until 10 seconds have passed and another segment becomes available.
		 * Please take this into account when setting these values.
		 */
		public static var MAX_SEG_BUFFER:int = 2;

		/**
		 * This overrides the value of the EXT-X-TARGETDURATION from any manifest we encounter.
		 *
		 * -1 causes this behavior to be disabled.
		 */
		public static var OVERRIDE_TARGET_DURATION:int = -1;

		/**
		 * Starting threshold in seconds; we use this threshold until we have stalled once.
		 *
		 * Playback will not begin until at least this much data is buffered.
		 *
		 * Setting this artifically low allows playback to start right away.
		 */
		public static var INITIAL_BUFFER_THRESHOLD:Number = 0.1;

		/**
		 * After we have stalled once, we switch to using this as the minimum 
		 * buffer period to allow playback.
		 *
		 * Playback will not begin until at least this much data is buffered.
		 */
		public static var NORMAL_BUFFER_THRESHOLD:Number = 21.0;
		
		/**
		 * How many seconds of video data should we keep in the buffer before 
		 * giving up on downloading for a while? If we add time via the bump
		 * mechanism (below), this is increased by the same amount.
		 */
		public static var MAX_BUFFER_AMOUNT:Number = 60.0;

		/**
		 * If we empty out, we'll increase our buffer by this amount to try to 
		 * avoid a subsequent emptying. We will increase up to
		 * BUFFER_EMPTY_MAX_INCREASE seconds more this way. The bump is not
		 * applied for the very first buffering event.
		 */
		public static var BUFFER_EMPTY_BUMP:Number = 5.0;

		/**
		 * Max time in seconds to allow BUFFER_EMPTY_BUMP to increase our
		 * buffer length.
		 */
		public static var BUFFER_EMPTY_MAX_INCREASE:Number = 30.0;

		/**
		 * We can force a zoom and pan factor to work around cropping issues on Chrome.
		 *
		 * Pan goes from -1 to 1, zoom from 1.0 to 8.0. See StageVideo zoom/pan for details.
		 */
		public static var FORCE_CROP_WORKAROUND_ZOOM_X:Number = 1.0;
		public static var FORCE_CROP_WORKAROUND_ZOOM_Y:Number = 1.0;
		public static var FORCE_CROP_WORKAROUND_PAN_X:Number = 0.0;
		public static var FORCE_CROP_WORKAROUND_PAN_Y:Number = 0.0;

		public static var FORCE_CROP_WORKAROUND_STAGEVIDEO:Boolean = false;
		public static var FORCE_CROP_WORKAROUND_DISPLAYOBJECT:Boolean = true;

 		/**
		 * Used to control the minimum, maximum, and preferred starting bitrates.
		 * -1 indicates there is no filtering. Non-zero values are intepreted as
		 * bits per second.
		 */
		public static var MIN_BITRATE:int = -1;
		public static var MAX_BITRATE:int = -1;
		public static var PREF_BITRATE:int = -1;


		public var type:String = DEFAULT;
		public var version:int;
		public var baseUrl:String;
		public var fullUrl:String;
		public var mediaSequence:int;
		public var allowCache:Boolean;
		public var targetDuration:Number;
		public var streamEnds:Boolean = false;
		public var playLists:Vector.<HLSManifestPlaylist> = new Vector.<HLSManifestPlaylist>();
		public var streams:Vector.<HLSManifestStream> = new Vector.<HLSManifestStream>();
		public var segments:Vector.<HLSManifestSegment> = new Vector.<HLSManifestSegment>();
		public var subtitlePlayLists:Vector.<HLSManifestPlaylist> = new Vector.<HLSManifestPlaylist>();
		public var subtitles:Vector.<SubTitleParser> = new Vector.<SubTitleParser>();
		public var keys:Vector.<HLSManifestEncryptionKey> = new Vector.<HLSManifestEncryptionKey>();
		public var goodManifest:Boolean = true;
		
		public var manifestLoaders:Vector.<URLLoader> = new Vector.<URLLoader>();
		public var manifestParsers:Vector.<HLSManifestParser> = new Vector.<HLSManifestParser>();
		private var manifestReloader:URLLoader = null;
		
		public var continuityEra:int = 0;
		
		private var _subtitlesLoading:int = 0;

		public var lastReloadRequestTime:int = -1;
		public var timestamp:int = -1;
		public var quality:int = -1;

		public function get estimatedWindowDuration():Number
		{
			return segments.length * targetDuration;
		}

		public function get bestGuessWindowDuration():Number
		{
			var accum:Number = 0.0;
			for(var i:int=0; i<segments.length; i++)
				accum += segments[i].duration;
			return accum;	
		}
		
		public function get isDVR():Boolean
		{
			return allowCache && !streamEnds;
		}
		
		public static function getNormalizedUrl( baseUrl:String, uri:String ):String
		{
			if(uri.substr(0, 1) == "/")
			{
				// Take the host from base and append the uri.
				var thirdSlash:int = 0;
				for(var i:int=0; i<3; i++)
					thirdSlash = baseUrl.indexOf("/", thirdSlash + 1);
				return baseUrl.substring(0, thirdSlash) + uri;
			}

			return ( uri.substr(0, 5) == "http:" || uri.substr(0, 6) == "https:" || uri.substr(0, 5) == "file:" ) ? uri : baseUrl + uri;
		}

		public function postToJS():void
		{
			// Generate JSON state!
			var jsonData:Object = {};
			for(var i:int=0; i<streams.length; i++)
			{
				var streamJson:Array = [];

				if(!streams[i].manifest)
					continue;

				for(var j:int=0; j<streams[i].manifest.segments.length; j++)
				{
					var curSeg:HLSManifestSegment = streams[i].manifest.segments[j];
					streamJson.push({ id: curSeg.id, url: curSeg.uri, start: curSeg.startTime, end: curSeg.startTime + curSeg.duration});
				}

				jsonData[streams[i].uri] = streamJson;
			}

			// Post it out.
			if(SEND_LOGS)
			{
				ExternalInterface.call( "onManifest", JSON.encode(jsonData) ); // JSON.stringify is not supported in 4.5.1 sdk, so stringify method will have to move to the JS side
			}
		}

		public function parse(input:String, _fullUrl:String):void
		{
			timestamp = getTimer();

			fullUrl = _fullUrl;
			// Do not strip query parameters on manifest - this breaks some manifests!
			//if(fullUrl.indexOf("?") >= 0){
			//	fullUrl = fullUrl.slice(0, fullUrl.indexOf("?"));
			//}
			baseUrl = fullUrl.substring(0, fullUrl.lastIndexOf("/") + 1);
			//logger.debug("BASE URL " + baseUrl);
			
			// Normalize line endings.
			var windowsEndingPattern:RegExp = /\r\n/g;
			input = input.replace(windowsEndingPattern, "\n");

			// split into array.
			var lines:Array = input.split("\n");
			
			// Process each line.
			var lastHint:* = null;
			var nextByteRangeStart:int = 0;
			
			var i:int = 0;
			for(i=0; i<lines.length; i++)
			{
				const curLine:String = lines[i];
				const curPrefix:String = curLine.substr(0,1);
				
				// Determine if we are parsing good information
				if (i == 0 && curLine.search("#EXTM3U") == -1)
				{
					CONFIG::LOGGING
					{
						logger.debug("Bad stream, #EXTM3U not found on the first line");
					}
					goodManifest = false;
					break;
				}
				
				// Ignore empty lines
				if ( curLine.length == 0 ) continue;
				
				if(curPrefix != "#" && curLine.length > 0)
				{
					// Specifying a media file, note it.
					if ( type != SUBTITLES ) 
					{
						var targetUrl:String = getNormalizedUrl( baseUrl, curLine );
						var segment:HLSManifestSegment = lastHint as HLSManifestSegment;
						if ( segment && segment.byteRangeStart != -1 )
						{
							// Append akamai ByteRange properties to URL
							var urlPostFix:String = targetUrl.indexOf( "?" ) == -1 ? "?" : "&";
							targetUrl += urlPostFix + "range=" + segment.byteRangeStart + "-" + segment.byteRangeEnd;
						}
						lastHint['uri'] = targetUrl;
					}
					else
					{
						lastHint.load( getNormalizedUrl( baseUrl, curLine ) );
					}
					continue;
				}
				
				// Othewise, we are processing a tag.
				var colonIndex:int = curLine.indexOf(":");
				var tagType:String = colonIndex > -1 ? curLine.substring( 1, colonIndex ) : curLine.substring( 1 );
				var tagParams:String = colonIndex > -1 ? curLine.substring( colonIndex + 1 ) : "";
				
				switch( tagType )
				{
					case "EXTM3U":
						CONFIG::LOGGING
						{
							if(i != 0)
							{
								logger.debug("Saw EXTM3U out of place! Ignoring...");
							}
						}
						break;
					
					case "EXT-X-TARGETDURATION":
						targetDuration = parseInt(tagParams);
						if (HLSManifestParser.OVERRIDE_TARGET_DURATION > 0){
							targetDuration = HLSManifestParser.OVERRIDE_TARGET_DURATION;
						}
						break;
					
					case "EXT-X-ENDLIST":
						// This will only show up in live streams if the stream is over.
						// This MUST (according to the spec) show up in any stream in which no more
						//     segments will be made available.
						streamEnds = true;
						break;

					case "EXT-X-KEY":
						if ( keys.length > 0 ) keys[ keys.length - 1 ].endSegmentId = segments.length - 1;
						var key:HLSManifestEncryptionKey = HLSManifestEncryptionKey.fromParams( tagParams );
						key.startSegmentId = segments.length;
						if ( key.url.search("://") == -1)
						{
							// If this is a relative URI, append it to our base URL
							key.url = getNormalizedUrl(baseUrl, key.url);
						}
						keys.push( key );
						break;
					
					case "EXT-X-VERSION":
						version = parseInt(tagParams);
						break;
					
					case "EXT-X-MEDIA-SEQUENCE":
						mediaSequence = parseInt(tagParams);
						break;
					
					case "EXT-X-ALLOW-CACHE":
						allowCache = tagParams == "YES" ? true : false;
						break;
					
					case "EXT-X-MEDIA":
						if ( tagParams.indexOf( "TYPE=AUDIO" ) != -1 )
						{
							var playList:HLSManifestPlaylist = HLSManifestPlaylist.fromString( tagParams ); 
							playList.uri = getNormalizedUrl( baseUrl, playList.uri );
							playLists.push( playList );
						}
						else if ( tagParams.indexOf( "TYPE=SUBTITLES" ) != -1 )
						{
							var subtitleList:HLSManifestPlaylist = HLSManifestPlaylist.fromString( tagParams );
							subtitleList.uri = getNormalizedUrl( baseUrl, subtitleList.uri );
							subtitlePlayLists.push( subtitleList );
						}
						else
						{
							CONFIG::LOGGING
							{
								logger.debug( "Encountered " + tagType + " tag that is not supported, ignoring." );
							}
						} 
						break;
					
					case "EXT-X-STREAM-INF":
						var substream:HLSManifestStream = HLSManifestStream.fromString(tagParams);
						lastHint = substream;
						if(lastHint.isProbablyVideo)
							streams.push(substream);
						break;
					
					case "EXTINF":
						if ( type == SUBTITLES )
						{
							var subTitle:SubTitleParser = new SubTitleParser();
							subTitle.addEventListener( Event.COMPLETE, onSubtitleLoaded );
							subtitles.push( subTitle );
							lastHint = subTitle;
							_subtitlesLoading++;
						}
						else
						{
							segments.push(new HLSManifestSegment());
							lastHint = segments[segments.length-1];
							var valueSplit:Array = tagParams.split(",");
							lastHint.duration = valueSplit[0];
							lastHint.continuityEra = continuityEra;
							if(valueSplit.length > 1)
								lastHint.title = valueSplit[1];
						}
						break;
					
					case "EXT-X-BYTERANGE":
						var hintAsSegment:HLSManifestSegment = lastHint as HLSManifestSegment;
						if ( hintAsSegment == null ) break;
						var byteRangeValues:Array = tagParams.split("@");
						hintAsSegment.byteRangeStart = byteRangeValues.length > 1 ? int( byteRangeValues[ 1 ] ) : nextByteRangeStart;
						hintAsSegment.byteRangeEnd = hintAsSegment.byteRangeStart + int( byteRangeValues[ 0 ] );
						nextByteRangeStart = hintAsSegment.byteRangeEnd + 1;
						break;
					
					case "EXT-X-DISCONTINUITY":
						CONFIG::LOGGING
						{
							logger.debug("Found Discontinuity");
							//logger.debug(input);
						}
						++continuityEra;
						break;
					
					case "EXT-X-PROGRAM-DATE-TIME":
						break;
					
					default:
						CONFIG::LOGGING
						{
							logger.debug("Unknown tag '" + tagType + "', ignoring...");
						}
						break;
				}		
			}
			
			// Sort submanifests.
			streams.sort(function(a:HLSManifestStream, b:HLSManifestStream):int
				{
					return a.bandwidth - b.bandwidth;
				});

			// Process any other manifests referenced.
			var pendingManifests:Boolean = false;
			var manifestItems:Vector.<BaseHLSManifestItem> = new <BaseHLSManifestItem>[].concat( streams, playLists, subtitlePlayLists );
			
			for( var k:int = 0; k < manifestItems.length; k++ )
			{
				// Request and parse the manifest.
				addItemToManifestLoader( manifestItems[k] );
			}
			
			var timeAccum:Number = 0.0;
			for (var m:int = 0; m < segments.length; ++m)
			{
				segments[m].id = mediaSequence + m; // set the id based on the media sequence
				segments[m].startTime = timeAccum;
				timeAccum += segments[m].duration;
			}
			
			CONFIG::LOGGING
			{
				for(i=0; i<keys.length; i++)
				{
					logger.debug("Key #" + i + " " + keys[i].toString());	
				}				
			}

			announceIfComplete();
		}
		
		private function verifyManifestItemIntegrity():void
		{
			var backupNum:int = 0;// the number of backup streams for each unique stream set
			
			// clear out bad manifests and match the streamEnd's value
			for (var i:int = 0; i <streams.length; i++)
			{
				if (streams[i].manifest != null && streams[i].manifest.goodManifest)
				{
					if (i == 0)
					{
						// if this is the first manifest and it is good, match the streamEnds value
						streamEnds = streams[0].manifest.streamEnds;
						continue;
					}
					
					if (streams[i].manifest.streamEnds == streamEnds)
					{
						// make sure each manifest matches the first good manifest's streamEnds value
						continue;
					}
				}
				// if we get here it means we have a bad manifest and we should get rid of it
				streams.splice(i--, 1);
			}
			
			// work through the manifests and set up backup streams
			for (i = streams.length - 1; i >= 0; --i)
			{				
				// only start the backup stream logic if we are not on our first checked (non-broken) stream
				if (i == streams.length - 1)
					continue;
				
				if (streams[i].bandwidth == streams[i+1].bandwidth)
				{
					backupNum++;
				}
				else if (backupNum > 0)
				{
					// link the main stream with it's backup stream(s)
					linkBackupStreams(i+1, backupNum, streams.splice(i+2, backupNum));
					
					backupNum = 0;
				}
			}
			
			// if we ended the loop with a backupNum greater than 0, we still have backup streams to add
			if (backupNum > 0)
				linkBackupStreams(0, backupNum, streams.splice(1, backupNum));
			
			for (var k:int = playLists.length - 1; k >= 0; --k)
			{
				if (playLists[k].manifest == null)
					playLists.splice(k, 1);
			}
			
			// TODO: Do we need to worry about subtitle playlists?
		}
		
		/**
		 * Links together the main stream and its backup streams into a circular linked list
		 */
		private function linkBackupStreams(mainStreamIndex:int, backupNum:int, backupStreams:Vector.<HLSManifestStream>):void
		{
			streams[mainStreamIndex].backupStream = backupStreams[0];
			streams[mainStreamIndex].numBackups = backupStreams[0].numBackups = backupNum;
			
			for (var i:int = 1; i < backupStreams.length; i++)
			{
				backupStreams[i-1].backupStream = backupStreams[i];
				backupStreams[i].numBackups = backupNum;
			}
			
			backupStreams[backupStreams.length - 1].backupStream = streams[mainStreamIndex];
		}

		/**
		 * Return a function that calls a specified function with the provided arguments
		 * APPENDED to its provided arguments.
		 * 
		 * For instance, function a(b,c) through closurizeAppend(a, c) becomes 
		 * a function(b) that calls function a(b,c);
		 */
		public static function closurizeAppend(func:Function, ...additionalArgs):Function
		{
			// Create a new function...
			return function(...localArgs):Object
			{
				// Combine parameter lists.
				var argsCopy:Array = localArgs.concat(additionalArgs);
				
				// Call the original function.
				return func.apply(null, argsCopy);
			}
		}
		
		protected function addItemToManifestLoader( item:BaseHLSManifestItem ):void
		{
			timestamp = getTimer();

			CONFIG::LOGGING
			{
				logger.debug("REQUESTING " + item.uri);
			}

			var manifestLoader:URLLoader = new URLLoader(new URLRequest(item.uri));
			manifestLoader.addEventListener(Event.COMPLETE, closurizeAppend(onManifestLoadComplete, item) );
			manifestLoader.addEventListener(IOErrorEvent.IO_ERROR, onManifestError);
			manifestLoader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onManifestError);
			manifestLoaders.push(manifestLoader);
		}
		
		protected function onManifestLoadComplete(e:Event, manifestItem:BaseHLSManifestItem):void
		{
			var manifestLoader:URLLoader = e.target as URLLoader;
			//logger.debug("HLSManifestParser.onManifestLoadComplete");
			//try {
				var resourceData:String = String(manifestLoader.data);
				
				// Remove from the active set.
				var idx:int = manifestLoaders.indexOf(manifestLoader);
				if(idx != -1)
					manifestLoaders.splice(idx, 1);
				else
				{
					CONFIG::LOGGING
					{
						logger.debug("Manifest loader not in loader list.");
					}
				}
				
				// Start parsing the manifest.
				var parser:HLSManifestParser = new HLSManifestParser();
				parser.type = manifestItem.type;
				manifestItem.manifest = parser;
				manifestParsers.push(parser);
				parser.addEventListener(Event.COMPLETE, onManifestParseComplete);
				parser.parse(resourceData, getNormalizedUrl(baseUrl, manifestItem.uri));
//			}
//			catch (parseError:Error)
//			{
//				logger.debug("ERROR loading manifest " + parseError.toString());
//			}

			timestamp = getTimer();
		}
		
		protected function onManifestParseComplete(e:Event):void
		{
			var idx:int = manifestParsers.indexOf(e.target);
			manifestParsers.splice(idx, 1);
			announceIfComplete(); 
		}
		
		protected function onManifestError(e:Event):void
		{
			CONFIG::LOGGING
			{
				logger.debug("ERROR loading manifest " + e.toString());
			}
			
			// Remove the loader from our list of loaders so that the load process completes
			var manifestLoader:URLLoader = e.target as URLLoader;
			var idx:int = manifestLoaders.indexOf(manifestLoader);
			
			if(idx != -1)
				manifestLoaders.splice(idx, 1);
			else
			{
				CONFIG::LOGGING
				{
					logger.debug("Manifest loader not in loader list.");
				}
			}

			announceIfComplete()
		}		
		
		protected function onManifestReloadError(e:Event):void
		{
			CONFIG::LOGGING
			{
				logger.debug("ERROR loading manifest " + e.toString());
			}
			
			// parse the error and send up the manifest url
			var event:IOErrorEvent = e as IOErrorEvent;
			var url:String = event.text.substring(event.text.search("URL: ") + 5);
			
			dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, false, false, url));
		}
		
		public function reload(manifest:HLSManifestParser):void
		{
			lastReloadRequestTime = getTimer();

			fullUrl = manifest.fullUrl;
			var manifestLoader:URLLoader = new URLLoader(new URLRequest(fullUrl));
			CONFIG::LOGGING
			{
				logger.debug("REQUESTING " + fullUrl);
			}
			manifestLoader.addEventListener(Event.COMPLETE, onManifestReloadComplete );
			manifestLoader.addEventListener(IOErrorEvent.IO_ERROR, onManifestReloadError);
			manifestLoader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onManifestReloadError);
		}
		
		public function onManifestReloadComplete(e:Event):void
		{
			var manifestLoader:URLLoader = e.target as URLLoader;
			//logger.debug("HLSManifestParser.onManifestReloadComplete");
			var resourceData:String = String(manifestLoader.data);
			CONFIG::LOGGING
			{
				logger.debug("onManifestReloadComplete - resourceData.length = " + resourceData.length);
			}
			timestamp = getTimer();
			
			// Start parsing the manifest.
			parse(resourceData, fullUrl);
		}
		
		private function onSubtitleLoaded( e:Event ):void
		{
			CONFIG::LOGGING
			{
				logger.debug( "SUBTITLE LOADED" );
			}
			_subtitlesLoading--;
			announceIfComplete(); 
		}
		
		private function announceIfComplete():void
		{
			if ( _subtitlesLoading == 0 && manifestParsers.length == 0 && manifestLoaders.length == 0 )
			{
				verifyManifestItemIntegrity();
				dispatchEvent(new Event(Event.COMPLETE));
			}
		}
	}
}