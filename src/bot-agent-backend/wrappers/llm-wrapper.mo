import LLM "mo:llm";

module {
  public type Model = {
    #Llama3_1_8B;
    #Qwen3_32B;
    #Llama4Scout;
  };

  public class LLMWrapper(model : ?Model) {
    var selectedModel : Model = switch (model) {
      case (null) #Qwen3_32B;
      case (?m) m;
    };

    public func chat(message : Text) : async Text {
      await LLM.prompt(selectedModel, message);
    };
  };
};
