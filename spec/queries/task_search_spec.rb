require "rails_helper"

RSpec.describe TaskSearch do
  let(:project) { create(:project) }

  def task(title, description = nil, **attributes) = create(:task, project: project, title: title, description: description, **attributes)
  def search(term, **options) = described_class.new(Task.all, term, **options).call.to_a

  describe "matching" do
    it "stems words, so a search for one form finds the others" do
      deployed = task("Deployed the billing service")
      task("Write the quarterly report")

      expect(search("deploying")).to eq([ deployed ])
      expect(search("services")).to eq([ deployed ])
    end

    it "looks in the description as well as the title" do
      hit = task("Quarterly review", "Check the invoice totals against billing")

      expect(search("invoice")).to eq([ hit ])
    end

    it "needs every word, unless told otherwise" do
      both = task("Fix invoice rounding", "billing module")
      only_invoice = task("Invoice template")

      expect(search("invoice billing")).to eq([ both ])
      expect(search("invoice or billing")).to contain_exactly(both, only_invoice)
    end

    it "supports quoted phrases and exclusions" do
      phrase = task("Send the invoice reminder")
      scattered = task("Reminder: the invoice is late")
      excluded = task("Invoice for the legal team", "legal")

      expect(search('"invoice reminder"')).to eq([ phrase ])
      expect(search("invoice -legal")).to contain_exactly(phrase, scattered)
      expect(search("invoice")).to include(excluded)
    end

    it "finds nothing for text that is only stop words or punctuation, and never raises" do
      task("The and of")

      [ "the and of", "", "   ", '"', "(", "&", "|", "!", ":*", "a:b", "'; DROP TABLE tasks; --", "\\", "<->", "🚀", "-", "or" ].each do |hostile|
        expect { search(hostile) }.not_to raise_error, "raised for #{hostile.inspect}"
      end
      expect(search("the and of")).to be_empty
    end
  end

  describe "ranking" do
    it "puts a title match above a description match, and a better match above a weaker one" do
      in_description = task("Quarterly review", "billing billing billing")
      in_title = task("Billing review")

      expect(search("billing")).to eq([ in_title, in_description ])
    end

    it "breaks ties by newest first, so pages are stable" do
      first = task("Billing fix")
      second = task("Billing fix")

      expect(search("billing")).to eq([ second, first ])
    end

    it "exposes the rank" do
      task("Billing")

      expect(search("billing").first.search_rank).to be_positive
    end
  end

  describe "highlights" do
    it "wraps the matched words, in the title and in a fragment of the description" do
      task("Fix billing", "Long text before it. The billing module rounds wrongly. More text after.")

      hit = search("billing").first

      expect(hit.title_highlight).to eq("Fix «billing»")
      expect(hit.description_highlight).to include("The «billing» module")
    end

    it "is plain text: nothing is escaped or added, so the client escapes it like any other field" do
      task('Fix "billing" & <3')

      expect(search("billing").first.title_highlight).to eq('Fix "«billing»" & <3')
    end

    it "copes with a missing description" do
      task("Billing")

      expect(search("billing").first.description_highlight).to eq("")
    end
  end

  describe "scope" do
    it "never returns discarded tasks (archived projects are the policy scope's job; see search_spec)" do
      task("Billing live")
      task("Billing gone", discarded_at: 1.day.ago)

      expect(search("billing").map(&:title)).to eq([ "Billing live" ])
    end

    it "can be narrowed to one project, and respects the scope it is given" do
      mine = task("Billing mine")
      elsewhere = create(:task, title: "Billing elsewhere")

      expect(search("billing", project_id: project.id)).to eq([ mine ])
      expect(described_class.new(Task.where(id: elsewhere.id), "billing").call.to_a).to eq([ elsewhere ])
    end
  end

  describe "the generated search vector" do
    it "follows updates" do
      record = task("Draft")

      record.update!(title: "Invoice")

      expect(search("invoice")).to eq([ record ])
      expect(search("draft")).to be_empty
    end

    it "is filled by bulk inserts too, which skip every callback" do
      now = Time.current
      Task.insert_all([ { project_id: project.id, creator_id: project.owner_id, title: "Bulk invoice", created_at: now, updated_at: now } ])

      expect(search("invoice").map(&:title)).to eq([ "Bulk invoice" ])
    end
  end

  it "refuses a very long query before running it" do
    expect { search("a" * 201) }.to raise_error(InvalidParameterError, /at most 200 characters/)
    expect { search("a" * 200) }.not_to raise_error
  end
end
