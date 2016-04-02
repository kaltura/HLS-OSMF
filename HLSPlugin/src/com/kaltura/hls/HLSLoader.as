package com.kaltura.hls
{	
	import com.kaltura.hls.m2ts.M2TSNetLoader;
	import com.kaltura.hls.manifest.HLSManifestParser;
	import com.kaltura.hls.manifest.HLSManifestPlaylist;
	import com.kaltura.hls.manifest.HLSManifestStream;
	
	import flash.events.ErrorEvent;
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.events.SecurityErrorEvent;
	import flash.net.URLLoader;
	import flash.net.URLRequest;
	
	import org.osmf.elements.VideoElement;
	import org.osmf.elements.proxyClasses.LoadFromDocumentLoadTrait;
	import org.osmf.events.MediaError;
	import org.osmf.events.MediaErrorEvent;
	import org.osmf.media.DefaultMediaFactory;
	import org.osmf.media.MediaElement;
	import org.osmf.media.MediaResourceBase;
	import org.osmf.media.MediaTypeUtil;
	import org.osmf.media.URLResource;
	import org.osmf.metadata.Metadata;
	import org.osmf.metadata.MetadataNamespaces;
	import org.osmf.net.DynamicStreamingItem;
	import org.osmf.net.StreamType;
	import org.osmf.net.StreamingItem;
	import org.osmf.net.StreamingItemType;
	import org.osmf.traits.LoadState;
	import org.osmf.traits.LoadTrait;
	import org.osmf.traits.LoaderBase;
	import org.osmf.utils.URL;
	
	public class HLSLoader extends LoaderBase
	{
		protected var loadTrait:LoadTrait;
		protected var manifestLoader:URLLoader;
		protected var parser:HLSManifestParser;
		protected var factory:DefaultMediaFactory = new DefaultMediaFactory();
		private var supportedMimeTypes:Vector.<String> = new Vector.<String>();

		public function HLSLoader()
		{
			super();
			
			supportedMimeTypes.push( "application/x-mpegURL" );
			supportedMimeTypes.push( "application/vnd.apple.mpegURL" );
			supportedMimeTypes.push( "vnd.apple.mpegURL" );
			supportedMimeTypes.push( "video/MP2T" );
		}
		
		override protected function executeLoad(loadTrait:LoadTrait):void 
		{
			this.loadTrait = loadTrait;
			
			updateLoadTrait(loadTrait, LoadState.LOADING);
			
			var url:String = URLResource(loadTrait.resource).url;
			manifestLoader = new URLLoader(new URLRequest(url));
			manifestLoader.addEventListener(Event.COMPLETE, onComplete);
			manifestLoader.addEventListener(IOErrorEvent.IO_ERROR, onError);
			manifestLoader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onError);
		}

		private function onComplete(event:Event):void 
		{
			manifestLoader.removeEventListener(Event.COMPLETE, onComplete);
			manifestLoader.removeEventListener(IOErrorEvent.IO_ERROR, onError);
			manifestLoader.removeEventListener(SecurityErrorEvent.SECURITY_ERROR, onError);
			
			try {
				var resourceData:String = String((event.target as URLLoader).data);

				
				var url:String = URLResource(loadTrait.resource).url;
				
				// Start parsing the manifest.
				parser = new HLSManifestParser();
				parser.addEventListener(Event.COMPLETE, onManifestComplete);
				parser.parse(resourceData, url);
			}
			catch (parseError:Error)
			{
				updateLoadTrait(loadTrait, LoadState.LOAD_ERROR);
				loadTrait.dispatchEvent(new MediaErrorEvent(MediaErrorEvent.MEDIA_ERROR, false, false, new MediaError(parseError.errorID, parseError.message)));
			}
		}
		
		protected function onManifestComplete(event:Event):void
		{
			trace("Manifest is loaded.");
			
			var isDVR:Boolean = false;
			
			// Construct the streaming resource and set it as our resource.
			var stream:HLSStreamingResource = new HLSStreamingResource(URLResource(loadTrait.resource).url, "", StreamType.DVR);
			stream.manifest = parser;
			
			var item:DynamicStreamingItem;
			var items:Vector.<DynamicStreamingItem> = new Vector.<DynamicStreamingItem>();
			for(var i:int=0; i<parser.streams.length; i++)
			{
				var curStream:HLSManifestStream = parser.streams[i];

				//If there is more than one streaming quality available, check to see if filtering is required
				if (parser.streams.length > 1)
				{
					//Checks to see if there are min/max bitrate restrictions then throws out the outliers
					if(HLSManifestParser.MAX_BITRATE != -1 && curStream.bandwidth > HLSManifestParser.MAX_BITRATE ||
						HLSManifestParser.MIN_BITRATE != -1 && curStream.bandwidth < HLSManifestParser.MIN_BITRATE)
					{
						continue;
					}
				}

				item = new DynamicStreamingItem(curStream.uri, curStream.bandwidth, curStream.width, curStream.height);
				curStream.dynamicStream = item;
				items.push(item);
				if ( !(curStream.manifest ? curStream.manifest.streamEnds : false) ) isDVR = true;
				
				// Create dynamic streaming items for the backup streams
				if (!curStream.backupStream)
					continue;
				
				var mainStream:HLSManifestStream = curStream;
				curStream = curStream.backupStream;
				while (curStream != mainStream)
				{
					curStream.dynamicStream = new DynamicStreamingItem(curStream.uri, curStream.bandwidth, curStream.width, curStream.height);
					curStream = curStream.backupStream;
				}
			}
			
			// Deal with single rate M3Us by stuffing a single stream in.
			if(items.length == 0)
			{
				item = new DynamicStreamingItem(URLResource(loadTrait.resource).url, 0, 0, 0);
				items.push(item);
				
				// Also set the DVR state
				if ( !stream.manifest.streamEnds ) isDVR = true;
			}
			
			var alternateAudioItems:Vector.<StreamingItem> = new <StreamingItem>[];
			for ( var j:int = 0; j < parser.playLists.length; j++ )
			{
				var playList:HLSManifestPlaylist = parser.playLists[ j ];
				if ( !playList.manifest ) continue;
				var audioItem:StreamingItem = new StreamingItem( StreamingItemType.AUDIO, playList.name, 0, playList );
				alternateAudioItems.push( audioItem );
			}
			
			stream.streamItems = items;
			stream.alternativeAudioStreamItems = alternateAudioItems;

			var preferredIndex:int;

			// If there is only one stream quality (or less) sets default to first stream
			if (items.length <= 1)
			{
				preferredIndex = 0;
			}
			else if (HLSManifestParser.PREF_BITRATE != -1)
			{
				// If there is a preferred bitrate set by kaltura, tests all streams to find highest bitrate below the preferred
				preferredIndex = 0;
				var preferredDistance:int = int.MAX_VALUE;

				for(var k:int=0; k<items.length; k++)
				{
					var curDist:int = Math.round(Math.abs(items[k].bitrate - HLSManifestParser.PREF_BITRATE));

					if(curDist > preferredDistance)
					{
						/// Reject too low or not improved items.
						continue;
					}
					else if (curDist == preferredDistance)
					{
						// If we have two bitrates the same distance from preferred, check them
						if (items[k].bitrate < items[preferredIndex].bitrate)
						{
							// If the current item bitrate is less than the preferredIndex, keep preferredIndex
							continue;
						}
					}

					// If all checks fail and the current item is superior, make the current item the preferredIndex.
					preferredIndex = k;
					preferredDistance = curDist;
				}
			}
			else
			{
				//Sets the preferred index to the middle (or higher of the 2 middle) bitrate streams
				preferredIndex = items.length / 2;
			}
			stream.initialIndex = preferredIndex;			
			
			stream.addMetadataValue( HLSMetadataNamespaces.PLAYABLE_RESOURCE_METADATA, true );
			
			var loadedElem:MediaElement = new HLSVideoElement( stream, new M2TSNetLoader() );
			LoadFromDocumentLoadTrait( loadTrait ).mediaElement = loadedElem;
			
			
			if ( parser.subtitlePlayLists.length > 0 )
			{
				var subtitleTrait:SubtitleTrait = new SubtitleTrait();
				subtitleTrait.playLists = parser.subtitlePlayLists;
				subtitleTrait.owningMediaElement = loadedElem;
				stream.subtitleTrait = subtitleTrait;
			}
			
			if ( isDVR )
			{
				var dvrMetadata:Metadata = new Metadata();
				stream.addMetadataValue(MetadataNamespaces.DVR_METADATA, dvrMetadata);
			}
			
			updateLoadTrait( loadTrait, LoadState.READY );
		}
		
		private function onError(event:ErrorEvent):void 
		{
			manifestLoader.removeEventListener(Event.COMPLETE, onComplete);
			manifestLoader.removeEventListener(IOErrorEvent.IO_ERROR, onError);
			manifestLoader.removeEventListener(SecurityErrorEvent.SECURITY_ERROR, onError);
			
			updateLoadTrait(loadTrait, LoadState.LOAD_ERROR);
			loadTrait.dispatchEvent(new MediaErrorEvent(MediaErrorEvent.MEDIA_ERROR, false, false, new MediaError(0, event.text)));
		}

		override public function canHandleResource(resource:MediaResourceBase):Boolean 
		{
			var supported:int = MediaTypeUtil.checkMetadataMatchWithResource(resource, new Vector.<String>(), supportedMimeTypes);
			
			if ( supported == MediaTypeUtil.METADATA_MATCH_FOUND )
				return true;

			if (!(resource is URLResource))
				return false;
			
			var url:URL = new URL((resource as URLResource).url);
			if (url.extension != "m3u8" && url.extension != "m3u")
				return false;
			
			return true;
		}
	
	}
}
