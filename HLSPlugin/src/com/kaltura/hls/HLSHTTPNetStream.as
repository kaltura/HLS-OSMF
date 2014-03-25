package com.kaltura.hls
{
	import com.kaltura.hls.manifest.HLSManifestParser;
	import com.kaltura.hls.manifest.HLSManifestPlaylist;
	
	import flash.net.NetConnection;
	
	import org.osmf.media.MediaResourceBase;
	import org.osmf.media.URLResource;
	import org.osmf.net.StreamType;
	import org.osmf.net.httpstreaming.HTTPNetStream;
	import org.osmf.net.httpstreaming.HTTPStreamingFactory;
	
	public class HLSHTTPNetStream extends HTTPNetStream
	{
		public function HLSHTTPNetStream(connection:NetConnection, factory:HTTPStreamingFactory, resource:URLResource=null)
		{
			super(connection, factory, resource);
		}
		
//		override protected function createAudioResource(resource:MediaResourceBase, streamName:String):MediaResourceBase
//		{
//			var hlsResource:HLSStreamingResource = resource as HLSStreamingResource;
//			var playLists:Vector.<HLSManifestPlaylist> = hlsResource.manifest.playLists;
//			
//			for ( var i:int = 0; i < playLists.length; i++ )
//				if ( playLists[ i ].name == streamName ) break;
//			
//			if ( i >= playLists.length )
//			{
//				trace( "AUDIO STREAM " + streamName + "NOT FOUND" );
//				return null;
//			}
//			
//			var playList:HLSManifestPlaylist = playLists[ i ];
//			var result:HLSStreamingResource = new HLSStreamingResource( playList.uri, playList.name, StreamType.DVR );
//			result.manifest = playList.manifest;
//			
//			return result;
//		}
	}
}