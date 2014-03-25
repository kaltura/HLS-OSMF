package com.kaltura.hls.manifest
{
	public class BaseHLSManifestItem
	{
		public var type:String = HLSManifestParser.DEFAULT;
		public var manifest:HLSManifestParser;
		public var uri:String = "";
		
		public function BaseHLSManifestItem()
		{
		}
	}
}