package com.kaltura.hls
{
	import org.osmf.elements.LoadFromDocumentElement;
	import org.osmf.media.MediaElement;
	import org.osmf.media.MediaResourceBase;
	import org.osmf.metadata.Metadata;

	public class HLSElement extends LoadFromDocumentElement
	{
		public static var element:HLSElement;
		
		public function HLSElement(resource:MediaResourceBase = null, loader:HLSLoader = null) 
		{
			element = this;
			
			if (loader == null) 
			{
				loader = new HLSLoader();
			}
			
			super(resource, loader);
		}
		
		override public function set proxiedElement(value:MediaElement):void
		{
			super.proxiedElement = value;
			if ( !value ) return;
			
			var hlsStream:HLSStreamingResource = value.resource as HLSStreamingResource;
			
			if ( !hlsStream || !hlsStream.subtitleTrait ) return;
			
			// Add our subtitle trait if it exists
			
			var trait:SubtitleTrait = hlsStream.subtitleTrait; 
			if ( hasTrait( trait.traitType ) ) removeTrait( trait.traitType );
			addTrait( trait.traitType, trait );
		}
	}
}