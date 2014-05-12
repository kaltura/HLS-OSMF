package com.kaltura.hls.m2ts
{
	import com.kaltura.hls.HLSMetadataNamespaces;
	
	import flash.net.NetConnection;
	import flash.net.NetStream;
	
	import org.osmf.media.MediaResourceBase;
	import org.osmf.media.URLResource;
	import org.osmf.net.httpstreaming.HTTPNetStream;
	import org.osmf.net.httpstreaming.HTTPStreamingFactory;
	import org.osmf.net.httpstreaming.HTTPStreamingNetLoader;
	import org.osmf.net.httpstreaming.HLSHTTPNetStream;
	
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
	}
}