package com.kaltura.hls.m2ts
{
	import com.kaltura.hls.HLSIndexHandler;
	import com.kaltura.hls.HLSStreamingResource;
	
	import org.osmf.media.MediaResourceBase;
	import org.osmf.net.httpstreaming.HTTPStreamingFactory;
	import org.osmf.net.httpstreaming.HTTPStreamingFileHandlerBase;
	import org.osmf.net.httpstreaming.HTTPStreamingIndexHandlerBase;
	import org.osmf.net.httpstreaming.HTTPStreamingIndexInfoBase;
	
	/**
	 * Factory for HLS file and index handlers.
	 */
	public class M2TSStreamingFactory extends HTTPStreamingFactory
	{
		public override function createFileHandler(resource:MediaResourceBase):HTTPStreamingFileHandlerBase
		{
			var hlsResource:HLSStreamingResource = resource as HLSStreamingResource;
			var result:M2TSFileHandler = new M2TSFileHandler();
			result.subtitleTrait = hlsResource.subtitleTrait;
			result.resource = hlsResource;
			return result;
		}
		
		public override function createIndexHandler(resource:MediaResourceBase, fileHandler:HTTPStreamingFileHandlerBase):HTTPStreamingIndexHandlerBase
		{
			return new HLSIndexHandler(resource, fileHandler);
		}
		
		public override function createIndexInfo(resource:MediaResourceBase):HTTPStreamingIndexInfoBase
		{
			return null;
		}
	}
}