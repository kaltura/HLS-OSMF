package com.kaltura.hls.manifest
{
	import com.kaltura.hls.subtitles.SubTitleParser;
	
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.events.IOErrorEvent;
	import flash.events.SecurityErrorEvent;
	import flash.net.URLLoader;
	import flash.net.URLRequest;

	import flash.utils.getTimer;
	
	/**
	 *  Fires Event.COMPLETE when the manifest is fully loaded. 
	 */
	public class HLSManifestParser extends EventDispatcher
	{
		public static const DEFAULT:String = "DEFAULT";
		public static const AUDIO:String = "AUDIO";
		public static const VIDEO:String = "VIDEO";
		public static const SUBTITLES:String = "SUBTITLES";
		
		public static var MAX_SEG_BUFFER:int = 4;
		
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
			return ( uri.substr(0, 5) == "http:" || uri.substr(0, 6) == "https:" || uri.substr(0, 5) == "file:" ) ? uri : baseUrl + uri;
		}

		public function parse(input:String, _fullUrl:String):void
		{
			timestamp = getTimer();

			fullUrl = _fullUrl;
			baseUrl = _fullUrl.substring(0, _fullUrl.lastIndexOf("/") + 1);
			//trace("BASE URL " + baseUrl);
			
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
					trace("Bad stream, #EXTM3U not found on the first line");
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
						if(i != 0)
							trace("Saw EXTM3U out of place! Ignoring...");
						break;
					
					case "EXT-X-TARGETDURATION":
						targetDuration = parseInt(tagParams);
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
						else trace( "Encountered " + tagType + " tag that is not supported, ignoring." );
						break;
					
					case "EXT-X-STREAM-INF":
						streams.push(HLSManifestStream.fromString(tagParams));
						lastHint = streams[streams.length-1];
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
						trace("Found Discontinuity");
						//trace(input);
						++continuityEra;
						break;
					
					case "EXT-X-PROGRAM-DATE-TIME":
						break;
					
					default:
						trace("Unknown tag '" + tagType + "', ignoring...");
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

			trace("REQUESTING " + item.uri);
			var manifestLoader:URLLoader = new URLLoader(new URLRequest(item.uri));
			manifestLoader.addEventListener(Event.COMPLETE, closurizeAppend(onManifestLoadComplete, item) );
			manifestLoader.addEventListener(IOErrorEvent.IO_ERROR, onManifestError);
			manifestLoader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onManifestError);
			manifestLoaders.push(manifestLoader);
		}
		
		protected function onManifestLoadComplete(e:Event, manifestItem:BaseHLSManifestItem):void
		{
			var manifestLoader:URLLoader = e.target as URLLoader;
			//trace("HLSManifestParser.onManifestLoadComplete");
			//try {
				var resourceData:String = String(manifestLoader.data);
				
				// Remove from the active set.
				var idx:int = manifestLoaders.indexOf(manifestLoader);
				if(idx != -1)
					manifestLoaders.splice(idx, 1);
				else
					trace("Manifest loader not in loader list.");
				
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
//				trace("ERROR loading manifest " + parseError.toString());
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
			trace("ERROR loading manifest " + e.toString());
			
			// Remove the loader from our list of loaders so that the load process completes
			var manifestLoader:URLLoader = e.target as URLLoader;
			var idx:int = manifestLoaders.indexOf(manifestLoader);
			
			if(idx != -1)
				manifestLoaders.splice(idx, 1);
			else
				trace("Manifest loader not in loader list.");

			announceIfComplete()
		}		
		
		protected function onManifestReloadError(e:Event):void
		{
			trace("ERROR loading manifest " + e.toString());
			
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
			trace("REQUESTING " + fullUrl);
			manifestLoader.addEventListener(Event.COMPLETE, onManifestReloadComplete );
			manifestLoader.addEventListener(IOErrorEvent.IO_ERROR, onManifestReloadError);
			manifestLoader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onManifestReloadError);
		}
		
		public function onManifestReloadComplete(e:Event):void
		{
			var manifestLoader:URLLoader = e.target as URLLoader;
			//trace("HLSManifestParser.onManifestReloadComplete");
			var resourceData:String = String(manifestLoader.data);
			trace("onManifestReloadComplete - resourceData.length = " + resourceData.length);
			timestamp = getTimer();
			
			// Start parsing the manifest.
			parse(resourceData, fullUrl);
		}
		
		private function onSubtitleLoaded( e:Event ):void
		{
			trace( "SUBTITLE LOADED" );
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