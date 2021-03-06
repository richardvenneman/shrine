class Shrine
  module Plugins
    # The backgrounding plugin enables you to remove processing/storing/deleting
    # of files from record's lifecycle, and put them into background jobs.
    # This is generally useful if you're doing processing and/or your store is
    # something other than Storage::FileSystem.
    #
    #     Shrine.plugin :backgrounding
    #     Shrine::Attacher.promote { |data| PromoteJob.perform_async(data) }
    #     Shrine::Attacher.delete { |data| DeleteJob.perform_async(data) }
    #
    # The `data` variable is a serializable hash containing all context needed
    # for promotion/deletion. You then just need to declare `PromoteJob` and
    # `DeleteJob`, and call `Shrine::Attacher.promote`/`Shrine::Attacher.delete`
    # with the data hash:
    #
    #     class PromoteJob
    #       include Sidekiq::Worker
    #
    #       def perform(data)
    #         Shrine::Attacher.promote(data)
    #       end
    #     end
    #
    #     class DeleteJob
    #       include Sidekiq::Worker
    #
    #       def perform(data)
    #         Shrine::Attacher.delete(data)
    #       end
    #     end
    #
    # Internally these methods will resolve all necessary objects, do the
    # promotion/deletion, and in case of promotion update the record with the
    # stored attachment.
    #
    # The examples above used Sidekiq, but obviously you can just as well use
    # any other backgrounding library. This setup will work globally for all
    # uploaders.
    #
    # The backgrounding plugin affects the `Shrine::Attacher` in a way that
    # `#_promote` and `#_delete` spawn background jobs, while `#promote` and
    # `#delete!` are always synchronous:
    #
    #     # asynchronous (spawn background jobs)
    #     attacher._promote
    #     attacher._delete(attachment)
    #
    #     # synchronous
    #     attacher.promote
    #     attacher.delete!(attachment)
    #
    # Both methods return the `Shrine::Attacher` instance (if the action didn't
    # abort), so you can use it to do additional actions:
    #
    #     def perform(data)
    #       attacher = Shrine::Attacher.promote(data)
    #       attacher.record.update(published: true) if attacher && attacher.record.is_a?(Post)
    #     end
    #
    # You can also write custom background jobs with `Attacher.dump` and
    # `Attacher.load`:
    #
    #     class User < Sequel::Model
    #       def after_commit
    #         super
    #         if some_condition
    #           data = Shrine::Attacher.dump(avatar_attacher)
    #           SomethingJob.perform_async(data)
    #         end
    #       end
    #     end
    #
    #     class SomethingJob
    #       include Sidekiq::Worker
    #       def perform(data)
    #         attacher = Shrine::Attacher.load(data)
    #         # ...
    #       end
    #     end
    #
    # If you're generating versions, and you want to process some versions in
    # the foreground before kicking off a background job, you can use the
    # recache plugin.
    module Backgrounding
      module AttacherClassMethods
        # If block is passed in, stores it to be called on promotion. Otherwise
        # resolves data into objects and calls `Attacher#promote`.
        def promote(data = nil, &block)
          if block
            shrine_class.opts[:backgrounding_promote] = block
          else
            attacher = load(data)
            cached_file = attacher.uploaded_file(data["attachment"])
            phase = data["phase"].to_sym if data["phase"]

            return if cached_file != attacher.get
            attacher.promote(cached_file, phase: phase) or return

            attacher
          end
        end

        # If block is passed in, stores it to be called on deletion. Otherwise
        # resolves data into objects and calls `Shrine#delete`.
        def delete(data = nil, &block)
          if block
            shrine_class.opts[:backgrounding_delete] = block
          else
            attacher = load(data)
            uploaded_file = attacher.uploaded_file(data["attachment"])
            phase = data["phase"].to_sym if data["phase"]

            attacher.delete!(uploaded_file, phase: phase)

            attacher
          end
        end

        # Delegates to `Attacher#dump`.
        def dump(attacher)
          attacher.dump
        end

        # Loads the data created by #dump, resolving the record and returning
        # the attacher.
        def load(data)
          record_class, record_id = data["record"]
          record_class = Object.const_get(record_class)
          record = find_record(record_class, record_id) ||
            record_class.new.tap { |object| object.id = record_id }

          name = data["name"]
          attacher = record.send("#{name}_attacher")

          attacher
        end
      end

      module AttacherMethods
        # Calls the promoting block (if registered) with a serializable data
        # hash.
        def _promote(uploaded_file = get, phase: nil)
          if background_promote = shrine_class.opts[:backgrounding_promote]
            data = self.class.dump(self).merge(
              "attachment" => uploaded_file.to_json,
              "phase"      => (phase.to_s if phase),
            )
            instance_exec(data, &background_promote)
          else
            super
          end
        end

        # Calls the deleting block (if registered) with a serializable data
        # hash.
        def _delete(uploaded_file, phase: nil)
          if background_delete = shrine_class.opts[:backgrounding_delete]
            data = self.class.dump(self).merge(
              "attachment" => uploaded_file.to_json,
              "phase"      => (phase.to_s if phase),
            )
            instance_exec(data, &background_delete)
            uploaded_file
          else
            super
          end
        end

        # Dumps all the information about the attacher in a serializable hash
        # suitable for passing as an argument to background jobs.
        def dump
          {
            "attachment" => (get && get.to_json),
            "record"     => [record.class.to_s, record.id.to_s],
            "name"       => name.to_s,
          }
        end
      end
    end

    register_plugin(:backgrounding, Backgrounding)
  end
end
