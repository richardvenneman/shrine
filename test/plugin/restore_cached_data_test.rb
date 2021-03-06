require "test_helper"

describe "the restore_cached_data plugin" do
  before do
    @attacher = attacher { plugin :restore_cached_data }
  end

  it "reextracts metadata of set cached files" do
    cached_file = @attacher.cache.upload(fakeio("image"))
    cached_file.metadata["size"] = 24354535
    @attacher.assign(cached_file.to_json)
    assert_equal 5, @attacher.get.metadata["size"]
  end

  it "skips extracting if the file is not cached" do
    stored_file = @attacher.store.upload(fakeio("image"))
    stored_file.metadata["size"] = 24354535
    @attacher.cache.expects(:extract_metadata).never
    @attacher.assign(stored_file.to_json)
  end
end
