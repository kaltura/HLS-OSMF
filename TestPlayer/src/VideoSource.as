package
{
	public class VideoSource
	{
		public var name:String;
		public var url:String;
		public var isLive:Boolean;

		public function VideoSource(name:String = null, url:String = null, isLive:Boolean = false) {
			this.name = name;
			this.url = url;
			this.isLive = isLive;
		}
	}
}
