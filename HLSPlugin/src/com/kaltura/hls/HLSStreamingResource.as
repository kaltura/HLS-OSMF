package com.kaltura.hls
{
	import com.kaltura.hls.manifest.HLSManifestParser;
	
	import org.osmf.net.DynamicStreamingResource;
	
	public class HLSStreamingResource extends DynamicStreamingResource
	{
		public function HLSStreamingResource(host:String, name:String="", streamType:String=null)
		{
			this.name = name;
			super(host, streamType);
		}
		
		public var manifest:HLSManifestParser;
		public var subtitleTrait:SubtitleTrait;
		public var name:String;
	}
}