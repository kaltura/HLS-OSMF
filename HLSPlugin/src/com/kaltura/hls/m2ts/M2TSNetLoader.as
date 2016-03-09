package com.kaltura.hls.m2ts
{
	import com.kaltura.hls.HLSDVRTimeTrait;
	import com.kaltura.hls.HLSDVRTrait;
	import com.kaltura.hls.HLSMetadataNamespaces;
	import com.kaltura.hls.manifest.HLSManifestParser;
	
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
	import org.osmf.traits.MediaTraitType;
	import org.osmf.traits.MediaTraitBase;
	import org.osmf.net.NetStreamDynamicStreamTrait;
	import org.osmf.net.NetStreamLoadTrait;

	import org.osmf.net.NetStreamSwitchManagerBase
	import org.osmf.net.metrics.BandwidthMetric;
	import org.osmf.net.DynamicStreamingResource;
	import org.osmf.net.httpstreaming.DefaultHTTPStreamingSwitchManager;
	import org.osmf.traits.DynamicStreamTrait;

	import org.osmf.net.metrics.*;
	import org.osmf.net.rules.*;
	import org.osmf.net.qos.*;
	import org.osmf.net.*;

	import com.kaltura.hls.DebugSwitchManager;

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

		protected function createDebugSwitchManager(connection:NetConnection, netStream:NetStream, dsResource:DynamicStreamingResource):NetStreamSwitchManagerBase
		{
			// Create a QoSInfoHistory, to hold a history of QoSInfo provided by the NetStream
			var netStreamQoSInfoHistory:QoSInfoHistory = createNetStreamQoSInfoHistory(netStream);
			
			// Create a MetricFactory, to be used by the metric repository for instantiating metrics
			var metricFactory:MetricFactory = createMetricFactory(netStreamQoSInfoHistory);
			
			// Create the MetricRepository, which caches metrics
			var metricRepository:MetricRepository = new MetricRepository(metricFactory);
			
			// Create the emergency rules
			var emergencyRules:Vector.<RuleBase> = new Vector.<RuleBase>();
			
			emergencyRules.push(new DroppedFPSRule(metricRepository, 10, 0.1));
			
			emergencyRules.push
				( new EmptyBufferRule
				  ( metricRepository
				  , EMPTY_BUFFER_RULE_SCALE_DOWN_FACTOR
				  )
				);
			
			emergencyRules.push
				( new AfterUpSwitchBufferBandwidthRule
				  ( metricRepository
					, AFTER_UP_SWITCH_BANDWIDTH_BUFFER_RULE_BUFFER_FRAGMENTS_THRESHOLD
					, AFTER_UP_SWITCH_BANDWIDTH_BUFFER_RULE_MIN_RATIO
				  )
				);
			
			// Create a NetStreamSwitcher, which will handle the low-level details of NetStream
			// stream switching
			var nsSwitcher:NetStreamSwitcher = new NetStreamSwitcher(netStream, dsResource);
			
			// Finally, return an instance of the DefaultSwitchManager, passing it
			// the objects we instatiated above
			return new DebugSwitchManager
				( netStream
				, nsSwitcher
				, metricRepository
				, emergencyRules
				, true
				);			
		}
		
		override protected function createNetStreamSwitchManager(connection:NetConnection, netStream:NetStream, dsResource:DynamicStreamingResource):NetStreamSwitchManagerBase
		{
			// Enable to use debug switch manager.
			if(false)
			{
				CONFIG::LOGGING
				{
					logger.info("Using debug switch manager.");
					return createDebugSwitchManager(connection, netStream, dsResource);
				}
			}

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
			
			if (HLSManifestParser.PREF_BITRATE != -1)
			{
				//Tests to see if a preferred bitrate is set
				trace("Preferred bitrate set - attempting to disable autoswitching");
				var autoSwitchTrait:DynamicStreamTrait = loadTrait.getTrait(MediaTraitType.DYNAMIC_STREAM) as DynamicStreamTrait;
				
				if (autoSwitchTrait != null)
				{
					//If the loadTrait already has a DYNAMIC_STREAM trait, it simply switches the autoSwitch bool to false
					autoSwitchTrait.autoSwitch = false;
					trace("loadTrait already possesses a DYNAMIC_STREAM trait, disabling autoswitching on existing trait");
				}
				else
				{
					//If the loadTrait does not have a DYNAMIC_STREAM trait, it creates one and switches the autoSwitch bool to false
					autoSwitchTrait = new NetStreamDynamicStreamTrait(loadTrait.netStream, 
																	  loadTrait.switchManager, 
																	  loadTrait.resource as DynamicStreamingResource);

					autoSwitchTrait.autoSwitch = false;

					loadTrait.setTrait(autoSwitchTrait);
					trace("loadTrait does not possess a DYNAMIC_STREAM trait, adding a new trait with autoswitching diabled");
				}
			}

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