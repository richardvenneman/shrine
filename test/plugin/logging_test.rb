require "test_helper"
require "stringio"
require "logger"

describe "the logging plugin" do
  def capture
    yield
    result = $out.string
    $out.reopen(StringIO.new)
    result
  end

  before do
    $out = StringIO.new
    @uploader = uploader { plugin :logging, stream: $out }
    @context = {name: :avatar, phase: :store}
    @context[:record] = Object.const_set("User", Struct.new(:id)).new(16)
  end

  after do
    Object.send(:remove_const, "User")
  end

  it "logs processing" do
    stdout = capture { @uploader.upload(fakeio) }
    refute_match /PROCESS/, stdout

    @uploader.instance_eval { def process(io, context); io; end }
    stdout = capture { @uploader.upload(fakeio) }
    assert_match /PROCESS \S+ 1-1 file \(\d+\.\d+s\)$/, stdout
  end

  it "logs storing" do
    stdout = capture { @uploader.upload(fakeio) }
    assert_match /STORE \S+ 1 file \(\d+\.\d+s\)$/, stdout
  end

  it "logs deleting" do
    uploaded_file = @uploader.upload(fakeio)
    stdout = capture { @uploader.delete(uploaded_file) }
    assert_match /DELETE \S+ 1 file \(\d+\.\d+s\)$/, stdout
  end

  it "counts versions" do
    @uploader.class.plugin :versions, names: [:thumb, :original]
    @uploader.instance_eval do
      def process(io, context)
        {thumb: StringIO.new, original: StringIO.new}
      end
    end
    stdout = capture do
      versions = @uploader.upload(fakeio)
      @uploader.delete(versions)
    end
    assert_match /PROCESS \S+ 1-2 files/, stdout
    assert_match /STORE \S+ 2 files/, stdout
    assert_match /DELETE \S+ 2 files/, stdout
  end

  it "counts array of files" do
    @uploader.class.plugin :multi_delete
    files = [@uploader.upload(fakeio), @uploader.upload(fakeio)]
    stdout = capture { @uploader.delete(files) }
    assert_match /DELETE \S+ 2 files/, stdout
  end

  it "outputs context data" do
    @uploader.instance_eval { def process(io, context); io; end }

    stdout = capture do
      uploaded_file = @uploader.upload(fakeio, @context)
      @uploader.delete(uploaded_file, @context)
    end

    assert_match /PROCESS\[store\] \S+\[:avatar\] User\[16\] 1-1 file \(\d+\.\d+s\)$/, stdout
    assert_match /STORE\[store\] \S+\[:avatar\] User\[16\] 1 file \(\d+\.\d+s\)$/, stdout
    assert_match /DELETE\[store\] \S+\[:avatar\] User\[16\] 1 file \(\d+\.\d+s\)$/, stdout
  end

  it "supports JSON format" do
    @uploader.opts[:logging_format] = :json
    stdout = capture { @uploader.upload(fakeio, @context) }
    JSON.parse(stdout[/\{.+\}/])
  end

  it "supports Heroku-style format" do
    @uploader.opts[:logging_format] = :heroku
    stdout = capture { @uploader.upload(fakeio, @context) }
    assert_match "action=store phase=store", stdout
  end

  it "accepts a custom logger" do
    @uploader.class.logger = (logger = Logger.new(nil))
    assert_equal logger, @uploader.class.logger
  end

  it "accepts model instances without an #id" do
    @context[:record].instance_eval { undef id }
    stdout = capture { @uploader.upload(fakeio, @context) }
    assert_match /STORE\[store\] \S+\[:avatar\] User 1 file \(\d+\.\d+s\)$/, stdout
  end

  it "works with hooks plugin in the right order" do
    @uploader = uploader do
      plugin :hooks
      plugin :logging, stream: $out
    end

    @uploader.class.class_eval do
      def around_store(io, context)
        self.class.logger.info "before logging"
        super
        self.class.logger.info "after logging"
      end
    end

    stdout = capture { @uploader.upload(fakeio) }
    assert_match "before logging", stdout.lines[0]
    assert_match "STORE",          stdout.lines[1]
    assert_match "after logging",  stdout.lines[2]
  end
end
