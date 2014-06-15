package com.kaltura.hls.m2ts
{
	import com.kaltura.hls.HLSDVRTimeTrait;
	import com.kaltura.hls.HLSDVRTrait;
	import com.kaltura.hls.HLSMetadataNamespaces;
	
	import flash.net.NetConnection;
	import flash.net.NetStream;
	
	import org.osmf.events.DVRStreamInfoEvent;
	import org.osmf.media.MediaResourceBase;
	import org.osmf.media.URLResource;
	import org.osmf.metadata.Metadata;
	import org.osmf.metadata.MetadataNamespaces;
	import org.osmf.net.NetStreamLoadTrait;
	import org.osmf.net.httpstreaming.HLSHTTPNetStream;
	import org.osmf.net.httpstreaming.HTTPStreamingFactory;
	import org.osmf.net.httpstreaming.HTTPStreamingNetLoader;
	import org.osmf.net.httpstreaming.dvr.DVRInfo;
	import org.osmf.traits.LoadState;
	
	/**
	 * Factory to identify and process MPEG2 TS via OSMF.
	 */
	public class M2TSNetLoader extends HTTPStreamingNetLoader
	{
		override public function canHandleResource( resource:MediaResourceBase ):Boolean
		{
			var metadata:Object = resource.getMetadataValue( HLSMetadataNamespaces.PLAYABLE_RESOURCE_METADATA );
			
			if ( metadata != null && metadata == true )
				return true;
			
			return false;
		}
		
		override protected function createNetStream(connection:NetConnection, resource:URLResource):NetStream
		{
			var factory:HTTPStreamingFactory = new M2TSStreamingFactory();
			var httpNetStream:HLSHTTPNetStream = new HLSHTTPNetStream(connection, factory, resource);
			return httpNetStream;
		}
		
		override protected function processFinishLoading(loadTrait:NetStreamLoadTrait):void
		{
			var resource:URLResource = loadTrait.resource as URLResource;
			
			if (!dvrMetadataPresent(resource))
			{
				updateLoadTrait(loadTrait, LoadState.READY);
				
				return;
			}
			
			var netStream:HLSHTTPNetStream = loadTrait.netStream as HLSHTTPNetStream;
			netStream.addEventListener(DVRStreamInfoEvent.DVRSTREAMINFO, onDVRStreamInfo);
			netStream.DVRGetStreamInfo(null);
			function onDVRStreamInfo(event:DVRStreamInfoEvent):void
			{
				netStream.removeEventListener(DVRStreamInfoEvent.DVRSTREAMINFO, onDVRStreamInfo);
				
				loadTrait.setTrait(new HLSDVRTrait(loadTrait.connection, netStream, event.info as DVRInfo));
				loadTrait.setTrait(new HLSDVRTimeTrait(loadTrait.connection, netStream, event.info as DVRInfo));
				updateLoadTrait(loadTrait, LoadState.READY);
			}
		}
		
		private function dvrMetadataPresent(resource:URLResource):Boolean
		{
			var metadata:Metadata = resource.getMetadataValue(MetadataNamespaces.DVR_METADATA) as Metadata;
			
			return (metadata != null);
		}
	}
}