package com.kaltura.hls.m2ts
{
	import com.kaltura.hls.HLSDVRTimeTrait;
	import com.kaltura.hls.HLSDVRTrait;
	import com.kaltura.hls.HLSMetadataNamespaces;
	
	import flash.net.NetConnection;
	import flash.net.NetStream;
	import flash.events.NetStatusEvent;
	
	import org.osmf.events.DVRStreamInfoEvent;
	import org.osmf.media.MediaResourceBase;
	import org.osmf.media.URLResource;
	import org.osmf.metadata.Metadata;
	import org.osmf.metadata.MetadataNamespaces;
	import org.osmf.net.NetStreamLoadTrait;
	import org.osmf.net.NetStreamCodes;
	import org.osmf.net.httpstreaming.HLSHTTPNetStream;
	import org.osmf.net.httpstreaming.HTTPStreamingFactory;
	import org.osmf.net.httpstreaming.HTTPStreamingNetLoader;
	import org.osmf.net.httpstreaming.dvr.DVRInfo;
	import org.osmf.traits.LoadState;

	import org.osmf.net.NetStreamSwitchManagerBase
	import org.osmf.net.metrics.BandwidthMetric;
	import org.osmf.net.DynamicStreamingResource;
	import org.osmf.net.httpstreaming.DefaultHTTPStreamingSwitchManager;

	import org.osmf.net.metrics.MetricType;
	import org.osmf.net.rules.BandwidthRule;
	
	CONFIG::LOGGING
	{
		import org.osmf.logging.Logger;
		import org.osmf.logging.Log;
	}

	/**
	 * Factory to identify and process MPEG2 TS via OSMF.
	 */
	public class M2TSNetLoader extends HTTPStreamingNetLoader
	{
        CONFIG::LOGGING
        {
            private static const logger:Logger = Log.getLogger("com.kaltura.hls.m2ts.M2TSNetLoader");
        }

		private var netStream:HLSHTTPNetStream;

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
		
		override protected function createNetStreamSwitchManager(connection:NetConnection, netStream:NetStream, dsResource:DynamicStreamingResource):NetStreamSwitchManagerBase
		{
			var switcher:DefaultHTTPStreamingSwitchManager = super.createNetStreamSwitchManager(connection, netStream, dsResource) as DefaultHTTPStreamingSwitchManager;
			
			// Since our segments are large, switch rapidly.

			// First, try to bias the bandwidth metric itself.
			var weights:Vector.<Number> = new Vector.<Number>;
			weights.push(1.0);
			weights.push(0.0);
			weights.push(0.0);
			var bw:BandwidthMetric = switcher.metricRepository.getMetric(MetricType.BANDWIDTH, weights) as BandwidthMetric;
			CONFIG::LOGGING
			{
				logger.info("Tried to override BandwidthMetric to N=1, and N=" + bw.weights.length);
			}

			// Second, bias the bandwidthrule.
			for(var i:int=0; i<switcher.normalRules.length; i++)
			{
				var bwr:BandwidthRule = switcher.normalRules[i] as BandwidthRule;
				if(!bwr)
					continue;

				bwr.weights.length = 3;
				bwr.weights[0] = 1.0;
				bwr.weights[1] = 0.0;
				bwr.weights[2] = 0.0;

				CONFIG::LOGGING
				{
					logger.debug("Adjusted BandwidthRule");
				}
			}

			// Third, adjust the switch logic to be less restrictive.
			switcher.maxReliabilityRecordSize = 3;
			switcher.maxUpSwitchLimit = -1;
			switcher.maxDownSwitchLimit = -1;

			return switcher;
		}

		override protected function processFinishLoading(loadTrait:NetStreamLoadTrait):void
		{
			// Set up DVR state updating.
			var resource:URLResource = loadTrait.resource as URLResource;
			
			if (!dvrMetadataPresent(resource))
			{
				updateLoadTrait(loadTrait, LoadState.READY);
				return;
			}
			
			netStream = loadTrait.netStream as HLSHTTPNetStream;
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