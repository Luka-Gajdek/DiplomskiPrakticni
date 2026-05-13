codeunit 50104 "AI Assistant Mgt."
{
    procedure SendMessage(UserMessage: Text; var ChatHistory: JsonArray): Text
    var
        Setup: Record "AI Assistant Setup";
        Context: Text;
        Reply: Text;
        Intent: Text;
        Parameter: Text;
        ForecastDays: Integer;
        VacationYear: Integer;
        SalesHistoryJson: Text;
        HistoryJson: Text;
    begin
        Setup := Setup.GetSetup();
        ValidateSetup(Setup);

        ChatHistory.WriteTo(HistoryJson);
        if HistoryJson = '' then
            HistoryJson := '[]';

        //LLM detecting intent
        DetectIntent(UserMessage, Setup, Intent, Parameter, ForecastDays, VacationYear, HistoryJson);

        // llama3 sometimes misses company policy questions, catch them here
        if (Intent = 'chat') and ContainsAny(UserMessage.ToLower(), 'rule,policy,expense,reimburse,compensat,dress code,conduct,working hours,vacation policy,safety,meeting,equipment,password,it policy') then
            Intent := 'company_rules';

        // llama3 confuses vacation/absence with chat sometimes, fix it here
        // needs to run before the stock_duration check or "how long was X absent" gets caught by stock keywords
        if (Intent <> 'vacation') and
           ContainsAny(UserMessage.ToLower(), 'absent,absence,days off,how many days off,how long was,how long were') then
            Intent := 'vacation';

        // stock duration questions often end up as item_info or chat, fix that here
        // require "stock"/"inventory" alongside "how long" so vacation questions don't get caught too
        if ((Intent = 'chat') or (Intent = 'item_info') or (Intent = 'predict_sales')) and
           (ContainsAny(UserMessage.ToLower(), 'stock last,days left,days of stock,run out') or
            (ContainsAny(UserMessage.ToLower(), 'how long') and ContainsAny(UserMessage.ToLower(), 'stock,inventory')))
        then
            Intent := 'stock_duration';

        // llama3 keeps classifying picture requests as item_info, override that here
        if ((Intent = 'chat') or (Intent = 'item_info')) and ContainsAny(UserMessage.ToLower(), 'picture,photo,image,show me a') then
            Intent := 'show_image';

        case Intent of
            'predict_sales':
                begin
                    if Parameter = '' then
                        Reply := 'Please specify an item number, e.g. "Predict sales for item 1000".'
                    else begin
                        Parameter := FindItemNo(Parameter);
                        SalesHistoryJson := BuildSalesHistoryJson(Parameter);
                        Reply := CallPredictSales(UserMessage, Parameter, SalesHistoryJson, ForecastDays, HistoryJson, Setup);
                    end;
                end;
            'item_info':
                begin
                    Context := BuildItemContext(Parameter);
                    Reply := CallChat(UserMessage, Context, HistoryJson, Setup);
                end;
            'vacation':
                begin
                    // LLM hallucinates on relative year phrases like "last year", just calculate it manually
                    if ContainsAny(UserMessage.ToLower(), 'last year,prošle godine,lani') then
                        VacationYear := Date2DMY(WorkDate(), 3) - 1
                    else if ContainsAny(UserMessage.ToLower(), 'next year,iduće godine,sljedeće godine') then
                        VacationYear := Date2DMY(WorkDate(), 3) + 1
                    else if VacationYear = 0 then
                        VacationYear := ExtractYearFromText(UserMessage);
                    // if LLM didn't pick up a name, check the last vacation reply in history
                    if Parameter = '' then
                        Parameter := ExtractLastVacationEmployee(ChatHistory);
                    Reply := BuildVacationReply(Parameter, VacationYear);
                end;
            'customer':
                begin
                    Context := BuildCustomerContext(UserMessage);
                    Reply := CallChat(UserMessage, Context, HistoryJson, Setup);
                end;
            'stock_duration':
                begin
                    if Parameter = '' then
                        Reply := 'Please specify an item, e.g. "How long will the stock of Tokyo Chair last?"'
                    else begin
                        Context := BuildStockDurationContext(Parameter, Setup);
                        Reply := CallChat(UserMessage, Context, HistoryJson, Setup);
                    end;
                end;
            'show_image':
                begin
                    Reply := BuildItemImageResponse(Parameter);
                end;
            'company_rules':
                begin
                    Context := GetCompanyRulesContext(Setup);
                    Reply := CallChat(UserMessage, Context, HistoryJson, Setup);
                end;
            'late_payment':
                begin
                    Reply := CallLatePaymentPrediction(UserMessage, Parameter, HistoryJson, Setup);
                end;
            else
                Reply := CallChat(UserMessage, '', HistoryJson, Setup);
        end;

        AppendHistory(ChatHistory, UserMessage, Reply);

        exit(Reply);
    end;

    local procedure AppendHistory(var ChatHistory: JsonArray; UserMessage: Text; Reply: Text)
    var
        UserMsg: JsonObject;
        AssistantMsg: JsonObject;
    begin
        UserMsg.Add('role', 'user');
        UserMsg.Add('content', UserMessage);
        ChatHistory.Add(UserMsg);

        AssistantMsg.Add('role', 'assistant');
        AssistantMsg.Add('content', Reply);
        ChatHistory.Add(AssistantMsg);

        // trim history, no point sending the whole thing to llama3
        while ChatHistory.Count > 5 do
            ChatHistory.RemoveAt(0);
    end;

    procedure TestConnection(Setup: Record "AI Assistant Setup")
    var
        Client: HttpClient;
        Response: HttpResponseMessage;
        Url: Text;
    begin
        Url := Setup."Backend URL" + '/health';
        Client.DefaultRequestHeaders().Add('X-API-Key', Setup."API Key");
        Client.DefaultRequestHeaders().Add('ngrok-skip-browser-warning', 'true'); // needed for ngrok tunnel; was originally hitting http://host.containerhelper.internal:8000 directly
        if Client.Get(Url, Response) then begin
            if Response.IsSuccessStatusCode() then
                Message('Connection successful! Backend is online.')
            else
                Error('Backend returned status %1.', Response.HttpStatusCode());
        end else
            Error('Could not reach the backend. Check the URL and that FastAPI + ngrok are running.');
    end;

    local procedure DetectIntent(UserMessage: Text; Setup: Record "AI Assistant Setup"; var Intent: Text; var Parameter: Text; var Days: Integer; var Year: Integer; HistoryJson: Text)
    var
        Client: HttpClient;
        RequestMsg: HttpRequestMessage;
        ResponseMsg: HttpResponseMessage;
        Content: HttpContent;
        Headers: HttpHeaders;
        Body: Text;
        ResponseText: Text;
        JsonObj: JsonObject;
        Token: JsonToken;
    begin
        Intent := 'chat';
        Parameter := '';
        Days := 30;
        Year := 0;

        if HistoryJson = '' then
            HistoryJson := '[]';
        Body := '{"message":' + JsonEscapeString(UserMessage) + ',"history":' + HistoryJson + '}';

        Content.WriteFrom(Body);
        Content.GetHeaders(Headers);
        Headers.Remove('Content-Type');
        Headers.Add('Content-Type', 'application/json');

        RequestMsg.Method := 'POST';
        RequestMsg.SetRequestUri(Setup."Backend URL" + '/detect-intent');
        RequestMsg.GetHeaders(Headers);
        Headers.Add('X-API-Key', Setup."API Key");
        Headers.Add('ngrok-skip-browser-warning', 'true'); // needed for ngrok tunnel; was originally hitting http://host.containerhelper.internal:8000 directly
        RequestMsg.Content := Content;

        if not Client.Send(RequestMsg, ResponseMsg) then
            exit;

        if not ResponseMsg.IsSuccessStatusCode() then
            exit;

        ResponseMsg.Content.ReadAs(ResponseText);

        if JsonObj.ReadFrom(ResponseText) then begin
            if JsonObj.Get('intent', Token) then
                Intent := Token.AsValue().AsText();
            if JsonObj.Get('parameter', Token) then
                Parameter := Token.AsValue().AsText();
            if JsonObj.Get('days', Token) then
                Days := Token.AsValue().AsInteger();
            if JsonObj.Get('year', Token) then
                Year := Token.AsValue().AsInteger();
        end;
    end;

    local procedure CallChat(UserMessage: Text; Context: Text; HistoryJson: Text; Setup: Record "AI Assistant Setup"): Text
    var
        Client: HttpClient;
        RequestMsg: HttpRequestMessage;
        ResponseMsg: HttpResponseMessage;
        Content: HttpContent;
        Headers: HttpHeaders;
        Body: Text;
        ResponseText: Text;
        JsonObj: JsonObject;
        ReplyToken: JsonToken;
    begin
        if HistoryJson = '' then
            HistoryJson := '[]';
        Body := '{"message":' + JsonEscapeString(UserMessage) + ',"context":' + JsonEscapeString(Context) + ',"history":' + HistoryJson + '}';

        Content.WriteFrom(Body);
        Content.GetHeaders(Headers);
        Headers.Remove('Content-Type');
        Headers.Add('Content-Type', 'application/json');

        RequestMsg.Method := 'POST';
        RequestMsg.SetRequestUri(Setup."Backend URL" + '/chat');
        RequestMsg.GetHeaders(Headers);
        Headers.Add('X-API-Key', Setup."API Key");
        Headers.Add('ngrok-skip-browser-warning', 'true'); // needed for ngrok tunnel; was originally hitting http://host.containerhelper.internal:8000 directly
        RequestMsg.Content := Content;

        if not Client.Send(RequestMsg, ResponseMsg) then
            Error('Failed to connect to AI backend. Ensure FastAPI and ngrok are running.');

        if not ResponseMsg.IsSuccessStatusCode() then
            Error('AI backend error: HTTP %1', ResponseMsg.HttpStatusCode());

        ResponseMsg.Content.ReadAs(ResponseText);

        if JsonObj.ReadFrom(ResponseText) then
            if JsonObj.Get('reply', ReplyToken) then
                exit(ReplyToken.AsValue().AsText());

        exit(ResponseText);
    end;

    local procedure CallPredictSales(UserMessage: Text; ItemNo: Text; HistoryJson: Text; ForecastDays: Integer; ChatHistoryJson: Text; Setup: Record "AI Assistant Setup"): Text
    var
        Client: HttpClient;
        RequestMsg: HttpRequestMessage;
        ResponseMsg: HttpResponseMessage;
        Content: HttpContent;
        Headers: HttpHeaders;
        Body: Text;
        ResponseText: Text;
        JsonObj: JsonObject;
        Token: JsonToken;
        PredQty: Decimal;
        Period: Text;
        Context: Text;
    begin
        Body := '{"item_no":' + JsonEscapeString(ItemNo) + ',"history":' + HistoryJson + ',"forecast_days":' + Format(ForecastDays) + '}';

        Content.WriteFrom(Body);
        Content.GetHeaders(Headers);
        Headers.Remove('Content-Type');
        Headers.Add('Content-Type', 'application/json');

        RequestMsg.Method := 'POST';
        RequestMsg.SetRequestUri(Setup."Backend URL" + '/predict-sales');
        RequestMsg.GetHeaders(Headers);
        Headers.Add('X-API-Key', Setup."API Key");
        Headers.Add('ngrok-skip-browser-warning', 'true'); // needed for ngrok tunnel; was originally hitting http://host.containerhelper.internal:8000 directly
        RequestMsg.Content := Content;

        if not Client.Send(RequestMsg, ResponseMsg) then
            Error('Failed to connect to AI backend.');

        if not ResponseMsg.IsSuccessStatusCode() then begin
            ResponseMsg.Content.ReadAs(ResponseText);
            exit('Sales prediction failed: ' + ResponseText);
        end;

        ResponseMsg.Content.ReadAs(ResponseText);

        if JsonObj.ReadFrom(ResponseText) then begin
            if JsonObj.Get('error', Token) then
                exit('Prediction error: ' + Token.AsValue().AsText());

            if JsonObj.Get('predicted_quantity', Token) then
                PredQty := Token.AsValue().AsDecimal();
            if JsonObj.Get('forecast_period', Token) then
                Period := Token.AsValue().AsText();

            Context := '{"sales_prediction":{"item_no":"' + ItemNo + '","predicted_quantity":' +
                       Format(PredQty, 0, '<Precision,2><Standard Format,9>') +
                       ',"forecast_days":' + Format(ForecastDays) +
                       ',"forecast_period":"' + Period + '"}}';

            exit(CallChat(UserMessage, Context, ChatHistoryJson, Setup));
        end;

        exit('Could not parse prediction response.');
    end;

    local procedure BuildVacationReply(SearchTerm: Text; RequestedYear: Integer): Text
    var
        Employee: Record Employee;
        AbsenceReg: Record "Employee Absence";
        Setup: Record "AI Assistant Setup";
        EntitlementDays: Integer;
        UsedDays: Decimal;
        RemainingDays: Decimal;
        CurrentYear: Integer;
        StartOfYear: Date;
        EndOfYear: Date;
        ReplyBuilder: TextBuilder;
        NameWords: List of [Text];
        FirstName: Text;
        LastName: Text;
        AbsenceEmployeeNo: Text;
        PeriodDays: Decimal;
    begin
        Setup := Setup.GetSetup();
        EntitlementDays := Setup."Vacation Entitlement Days";
        if RequestedYear > 0 then
            CurrentYear := RequestedYear
        else
            CurrentYear := Date2DMY(WorkDate(), 3);
        StartOfYear := DMY2Date(1, 1, CurrentYear);
        EndOfYear := DMY2Date(31, 12, CurrentYear);

        SearchTerm := StripLeadingPrepositions(SearchTerm.Trim());

        if SearchTerm = '' then
            exit('Please specify an employee name or ID.');

        // Try exact match by No. first
        if not Employee.Get(SearchTerm) then begin
            Employee.SetFilter("No.", '@*' + SearchTerm + '*');
            if not Employee.FindFirst() then begin
                Employee.Reset();
                NameWords := SearchTerm.Split(' ');
                if NameWords.Count >= 2 then begin
                    FirstName := NameWords.Get(1);
                    LastName := NameWords.Get(NameWords.Count);
                    Employee.SetFilter("First Name", '@*' + FirstName + '*');
                    Employee.SetFilter("Last Name", '@*' + LastName + '*');
                    if not Employee.FindFirst() then begin
                        Employee.Reset();
                        Employee.SetFilter("First Name", '@*' + FirstName + '*');
                        if not Employee.FindFirst() then begin
                            Employee.Reset();
                            Employee.SetFilter("Last Name", '@*' + LastName + '*');
                            if not Employee.FindFirst() then
                                exit('No employee found matching "' + SearchTerm + '".');
                        end;
                    end;
                end else begin
                    Employee.SetFilter("First Name", '@*' + SearchTerm + '*');
                    if not Employee.FindFirst() then begin
                        Employee.Reset();
                        Employee.SetFilter("Last Name", '@*' + SearchTerm + '*');
                        if not Employee.FindFirst() then
                            exit('No employee found matching "' + SearchTerm + '".');
                    end;
                end;
            end;
        end;

        AbsenceEmployeeNo := Employee."No.";

        ReplyBuilder.Append(Employee."First Name" + ' ' + Employee."Last Name");
        ReplyBuilder.Append(' — Absences in ');
        ReplyBuilder.Append(Format(CurrentYear));
        ReplyBuilder.Append('\n\n');

        AbsenceReg.Reset();
        AbsenceReg.SetRange("Employee No.", AbsenceEmployeeNo);
        AbsenceReg.SetRange("From Date", StartOfYear, EndOfYear);
        if AbsenceReg.FindSet() then
            repeat
                if AbsenceReg."To Date" <> 0D then
                    PeriodDays := CountWorkingDays(AbsenceReg."From Date", AbsenceReg."To Date")
                else begin
                    case AbsenceReg."Unit of Measure Code" of
                        'HOUR':
                            PeriodDays := Round(AbsenceReg.Quantity / 8, 1);
                        'DAY':
                            PeriodDays := Round(AbsenceReg.Quantity, 1);
                        else
                            PeriodDays := 1;
                    end;
                    if PeriodDays <= 0 then
                        PeriodDays := 1;
                end;
                if not (AbsenceReg."Cause of Absence Code" in ['SICK', 'DAYOFF']) then
                    UsedDays += PeriodDays;

                ReplyBuilder.Append(Format(AbsenceReg."From Date", 0, '<Day,2> <Month Text,3> <Year4>'));
                if AbsenceReg."To Date" <> 0D then begin
                    ReplyBuilder.Append(' – ');
                    ReplyBuilder.Append(Format(AbsenceReg."To Date", 0, '<Day,2> <Month Text,3> <Year4>'));
                end;
                ReplyBuilder.Append('   ');
                ReplyBuilder.Append(AbsenceReg."Cause of Absence Code");
                ReplyBuilder.Append('   ');
                ReplyBuilder.Append(Format(PeriodDays, 0, '<Integer>'));
                if PeriodDays = 1 then
                    ReplyBuilder.Append(' day')
                else
                    ReplyBuilder.Append(' days');
                ReplyBuilder.Append('\n');
            until AbsenceReg.Next() = 0
        else begin
            ReplyBuilder.Append('No absences recorded.');
            ReplyBuilder.Append('\n');
        end;

        RemainingDays := EntitlementDays - UsedDays;

        ReplyBuilder.Append('\nTotal: ');
        ReplyBuilder.Append(Format(UsedDays, 0, '<Integer>'));
        ReplyBuilder.Append(' days of vacation used   |   Vacation entitlement remaining:');
        ReplyBuilder.Append(Format(RemainingDays, 0, '<Integer>'));
        ReplyBuilder.Append(' of ');
        ReplyBuilder.Append(Format(EntitlementDays));
        ReplyBuilder.Append(' days');

        exit(ReplyBuilder.ToText());
    end;

    local procedure BuildSalesHistoryJson(ItemNo: Text): Text
    var
        ILE: Record "Item Ledger Entry";
        JsonBuilder: TextBuilder;
        First: Boolean;
        Qty: Decimal;
    begin
        ILE.Reset();
        ILE.SetRange("Item No.", ItemNo);
        ILE.SetRange("Entry Type", ILE."Entry Type"::Sale);
        ILE.SetFilter("Posting Date", '>=%1', CalcDate('<-2Y>', Today()));

        JsonBuilder.Append('[');
        First := true;
        if ILE.FindSet() then
            repeat
                Qty := Abs(ILE.Quantity);

                if not First then
                    JsonBuilder.Append(',');
                JsonBuilder.Append('{"date":"');
                JsonBuilder.Append(Format(ILE."Posting Date", 0, '<Year4>-<Month,2>-<Day,2>'));
                JsonBuilder.Append('","quantity":');
                JsonBuilder.Append(Format(Qty, 0, '<Integer>'));
                JsonBuilder.Append('}');
                First := false;
            until ILE.Next() = 0;
        JsonBuilder.Append(']');

        exit(JsonBuilder.ToText());
    end;

    local procedure BuildItemContext(SearchTerm: Text): Text
    var
        Item: Record Item;
        JsonBuilder: TextBuilder;
    begin
        SearchTerm := StripLeadingPrepositions(SearchTerm.Trim());

        if SearchTerm = '' then
            exit('{"items":[]}');

        Item.SetRange(Blocked, false);
        Item.SetFilter(Description, BuildWordFilter(SearchTerm));
        if not Item.FindFirst() then begin
            Item.Reset();
            Item.SetFilter(Description, BuildWordFilter(SearchTerm.TrimEnd('s')));
            if not Item.FindFirst() then begin
                Item.Reset();
                Item.SetFilter("No.", '@*' + SearchTerm + '*');
                if not Item.FindFirst() then
                    exit('{"items":[]}');
            end;
        end;

        Item.CalcFields(Inventory);

        JsonBuilder.Append('{"items":[{"no":"');
        JsonBuilder.Append(Item."No.");
        JsonBuilder.Append('","description":"');
        JsonBuilder.Append(EscapeJson(Item.Description));
        JsonBuilder.Append('","inventory":');
        JsonBuilder.Append(Format(Item.Inventory, 0, '<Precision,2><Standard Format,0>'));
        JsonBuilder.Append(',"unit_price":');
        JsonBuilder.Append(Format(Item."Unit Price", 0, '<Precision,2><Standard Format,0>'));
        JsonBuilder.Append('}]}');

        exit(JsonBuilder.ToText());
    end;

    local procedure BuildCustomerContext(UserMessage: Text): Text
    var
        Customer: Record Customer;
        JsonBuilder: TextBuilder;
        SearchTerm: Text;
        First: Boolean;
        Count: Integer;
    begin
        SearchTerm := ExtractSearchTerm(UserMessage, 'customer,client');

        if SearchTerm <> '' then begin
            Customer.SetFilter(Name, BuildWordFilter(SearchTerm));
            if not Customer.FindFirst() then begin
                Customer.Reset();
                Customer.SetFilter("No.", '@*' + SearchTerm + '*');
            end;
        end;

        JsonBuilder.Append('{"customers":[');
        First := true;
        Count := 0;
        if Customer.FindSet() then
            repeat
                if Count < 5 then begin
                    if not First then
                        JsonBuilder.Append(',');
                    JsonBuilder.Append('{"no":"');
                    JsonBuilder.Append(Customer."No.");
                    JsonBuilder.Append('","name":"');
                    JsonBuilder.Append(EscapeJson(Customer.Name));
                    JsonBuilder.Append('","balance":');
                    JsonBuilder.Append(Format(Customer."Balance (LCY)", 0, '<Precision,2><Standard Format,0>'));
                    JsonBuilder.Append(',"city":"');
                    JsonBuilder.Append(EscapeJson(Customer.City));
                    JsonBuilder.Append('"}');
                    First := false;
                    Count += 1;
                end;
            until (Customer.Next() = 0) or (Count >= 5);
        JsonBuilder.Append(']}');

        exit(JsonBuilder.ToText());
    end;

    local procedure BuildItemImageResponse(SearchTerm: Text): Text
    var
        Item: Record Item;
        PictureBase64: Text;
    begin
        SearchTerm := StripLeadingPrepositions(SearchTerm.Trim());

        if SearchTerm = '' then
            exit('Please specify which item you want to see, e.g. "Show me a picture of the Tokyo Chair".');

        Item.SetRange(Blocked, false);
        Item.SetFilter(Description, BuildWordFilter(SearchTerm));
        if not Item.FindFirst() then begin
            Item.Reset();
            Item.SetFilter(Description, BuildWordFilter(SearchTerm.TrimEnd('s')));
            if not Item.FindFirst() then begin
                Item.Reset();
                Item.SetFilter("No.", '@*' + SearchTerm + '*');
                if not Item.FindFirst() then
                    exit('Sorry, I couldn''t find an item matching "' + SearchTerm + '".');
            end;
        end;

        PictureBase64 := GetItemPictureBase64(Item);
        if PictureBase64 = '' then
            exit('I found **' + Item.Description + '** (No. ' + Item."No." + ') but it has no picture on file.');

        exit('Here is the picture of **' + Item.Description + '**:\n[IMG:' + PictureBase64 + ']');
    end;

    local procedure GetItemPictureBase64(var Item: Record Item): Text
    var
        TenantMedia: Record "Tenant Media";
        Base64Convert: Codeunit "Base64 Convert";
        IStream: InStream;
        MediaGuid: Guid;
        MimeType: Text;
    begin
        if Item.Picture.Count() = 0 then
            exit('');

        MediaGuid := Item.Picture.Item(1);
        if not TenantMedia.Get(MediaGuid) then
            exit('');

        TenantMedia.CalcFields(Content);
        if not TenantMedia.Content.HasValue() then
            exit('');

        MimeType := TenantMedia."Mime Type";
        if MimeType = '' then
            MimeType := 'image/jpeg';

        TenantMedia.Content.CreateInStream(IStream);
        exit('data:' + MimeType + ';base64,' + Base64Convert.ToBase64(IStream));
    end;

    local procedure ExtractSearchTerm(UserMessage: Text; Keywords: Text): Text
    var
        KeywordList: List of [Text];
        Keyword: Text;
        Pos: Integer;
        Remainder: Text;
    begin
        KeywordList := Keywords.Split(',');
        foreach Keyword in KeywordList do begin
            Pos := UserMessage.ToLower().IndexOf(Keyword.ToLower());
            if Pos > 0 then begin
                Remainder := CopyStr(UserMessage, Pos + StrLen(Keyword) + 1).Trim();
                if StrLen(Remainder) > 2 then
                    exit(Remainder);
            end;
        end;
        exit('');
    end;

    local procedure StripLeadingPrepositions(Value: Text): Text
    var
        Prepositions: List of [Text];
        Prep: Text;
        Lower: Text;
        Changed: Boolean;
    begin
        Prepositions := 'for,of,about,on,the,days,off'.Split(',');
        repeat
            Changed := false;
            foreach Prep in Prepositions do begin
                Lower := Value.ToLower();
                if Lower.StartsWith(Prep + ' ') then begin
                    Value := CopyStr(Value, StrLen(Prep) + 2).Trim();
                    Changed := true;
                end;
            end;
        until not Changed;
        exit(Value.Trim());
    end;

    local procedure BuildWordFilter(SearchTerm: Text): Text
    var
        Words: List of [Text];
        Word: Text;
        Filter: Text;
    begin
        Words := SearchTerm.Split(' ');
        foreach Word in Words do begin
            Word := Word.Trim();
            if StrLen(Word) > 2 then begin
                if Filter <> '' then
                    Filter += '&';
                Filter += '@*' + Word + '*';
            end;
        end;
        if Filter = '' then
            Filter := '@*' + SearchTerm + '*';
        exit(Filter);
    end;

    local procedure ExtractYearFromText(Value: Text): Integer
    var
        i: Integer;
        Chunk: Text;
        Year: Integer;
    begin
        for i := 1 to StrLen(Value) - 3 do begin
            Chunk := CopyStr(Value, i, 4);
            if Evaluate(Year, Chunk) then
                if (Year >= 2020) and (Year <= 2099) then
                    exit(Year);
        end;
        exit(0);
    end;

    local procedure ExtractLastVacationEmployee(ChatHistory: JsonArray): Text
    var
        i: Integer;
        Token: JsonToken;
        MsgObj: JsonObject;
        Role: Text;
        Content: Text;
        DashPos: Integer;
    begin
        // go backwards through history, vacation replies always start with "FirstName LastName — Absences in"
        for i := ChatHistory.Count - 1 downto 0 do begin
            ChatHistory.Get(i, Token);
            MsgObj := Token.AsObject();
            if MsgObj.Get('role', Token) then
                Role := Token.AsValue().AsText();
            if Role = 'assistant' then
                if MsgObj.Get('content', Token) then begin
                    Content := Token.AsValue().AsText();
                    DashPos := Content.IndexOf(' — Absences in ');
                    if DashPos > 0 then
                        exit(CopyStr(Content, 1, DashPos - 1));
                end;
        end;
        exit('');
    end;

    local procedure ContainsAny(Source: Text; Keywords: Text): Boolean
    var
        KeywordList: List of [Text];
        Keyword: Text;
    begin
        KeywordList := Keywords.Split(',');
        foreach Keyword in KeywordList do
            if Source.ToLower().Contains(Keyword.ToLower()) then
                exit(true);
        exit(false);
    end;

    local procedure JsonEscapeString(Value: Text): Text
    begin
        exit('"' + EscapeJson(Value) + '"');
    end;

    local procedure EscapeJson(Value: Text): Text
    var
        CR: Char;
        LF: Char;
        Tab: Char;
    begin
        CR := 13;
        LF := 10;
        Tab := 9;
        Value := Value.Replace('\', '\\');
        Value := Value.Replace('"', '\"');
        Value := Value.Replace('/', '\/');
        Value := Value.Replace(Format(CR), '\r');
        Value := Value.Replace(Format(LF), '\n');
        Value := Value.Replace(Format(Tab), '\t');
        exit(Value);
    end;

    local procedure GetCompanyRulesContext(Setup: Record "AI Assistant Setup"): Text
    var
        Client: HttpClient;
        RequestMsg: HttpRequestMessage;
        ResponseMsg: HttpResponseMessage;
        Headers: HttpHeaders;
        ResponseText: Text;
        JsonObj: JsonObject;
        Token: JsonToken;
        Rules: Text;
    begin
        RequestMsg.Method := 'GET';
        RequestMsg.SetRequestUri(Setup."Backend URL" + '/company-rules');
        RequestMsg.GetHeaders(Headers);
        Headers.Add('X-API-Key', Setup."API Key");
        Headers.Add('ngrok-skip-browser-warning', 'true'); // needed for ngrok tunnel; was originally hitting http://host.containerhelper.internal:8000 directly

        if not Client.Send(RequestMsg, ResponseMsg) then
            exit('{"error":"Could not reach backend to load company rules."}');

        if not ResponseMsg.IsSuccessStatusCode() then
            exit('{"error":"Failed to load company rules."}');

        ResponseMsg.Content.ReadAs(ResponseText);

        if JsonObj.ReadFrom(ResponseText) then
            if JsonObj.Get('rules', Token) then
                Rules := Token.AsValue().AsText();

        exit('{"company_rules":' + JsonEscapeString(Rules) + '}');
    end;


    local procedure FindItemNo(SearchTerm: Text): Text
    var
        Item: Record Item;
    begin
        SearchTerm := StripLeadingPrepositions(SearchTerm.Trim());

        // Try exact item number first
        if Item.Get(SearchTerm) then
            exit(Item."No.");

        // Try description match
        Item.Reset();
        Item.SetRange(Blocked, false);
        Item.SetFilter(Description, BuildWordFilter(SearchTerm));
        if not Item.FindFirst() then begin
            Item.Reset();
            Item.SetRange(Blocked, false);
            Item.SetFilter(Description, BuildWordFilter(SearchTerm.TrimEnd('s')));
        end;
        if Item.FindFirst() then
            exit(Item."No.");

        // just return whatever was passed, BuildSalesHistoryJson handles not finding anything
        exit(SearchTerm);
    end;

    local procedure BuildStockDurationContext(ItemParam: Text; Setup: Record "AI Assistant Setup"): Text
    var
        Item: Record Item;
        Client: HttpClient;
        RequestMsg: HttpRequestMessage;
        ResponseMsg: HttpResponseMessage;
        Content: HttpContent;
        Headers: HttpHeaders;
        Body: Text;
        ResponseText: Text;
        JsonObj: JsonObject;
        Token: JsonToken;
        HistoryJson: Text;
        PredQty: Decimal;
        DailyRate: Decimal;
        DaysRemaining: Decimal;
    begin
        ItemParam := StripLeadingPrepositions(ItemParam.Trim());

        Item.SetRange(Blocked, false);
        Item.SetFilter(Description, BuildWordFilter(ItemParam));
        Item.SetAutoCalcFields(Inventory);
        if not Item.FindFirst() then begin
            Item.Reset();
            Item.SetFilter(Description, BuildWordFilter(ItemParam.TrimEnd('s')));
            Item.SetAutoCalcFields(Inventory);
            if not Item.FindFirst() then begin
                Item.Reset();
                Item.SetAutoCalcFields(Inventory);
                if not Item.Get(ItemParam) then
                    exit('{"error":"Item not found: ' + ItemParam + '"}');
            end;
        end;

        HistoryJson := BuildSalesHistoryJson(Item."No.");

        Body := '{"item_no":' + JsonEscapeString(Item."No.") + ',"history":' + HistoryJson + ',"forecast_days":90}';
        Content.WriteFrom(Body);
        Content.GetHeaders(Headers);
        Headers.Remove('Content-Type');
        Headers.Add('Content-Type', 'application/json');

        RequestMsg.Method := 'POST';
        RequestMsg.SetRequestUri(Setup."Backend URL" + '/predict-sales');
        RequestMsg.GetHeaders(Headers);
        Headers.Add('X-API-Key', Setup."API Key");
        Headers.Add('ngrok-skip-browser-warning', 'true'); // needed for ngrok tunnel; was originally hitting http://host.containerhelper.internal:8000 directly
        RequestMsg.Content := Content;

        if not Client.Send(RequestMsg, ResponseMsg) then
            exit('{"error":"Could not reach backend."}');

        ResponseMsg.Content.ReadAs(ResponseText);

        if not JsonObj.ReadFrom(ResponseText) then
            exit('{"error":"Invalid prediction response."}');

        if JsonObj.Get('error', Token) then
            exit('{"error":' + JsonEscapeString(Token.AsValue().AsText()) + '}');

        if JsonObj.Get('predicted_quantity', Token) then
            PredQty := Token.AsValue().AsDecimal();

        if PredQty <= 0 then
            exit('{"error":"Cannot calculate stock duration — no sales data available for this item."}');

        DailyRate := PredQty / 90;
        if DailyRate > 0 then
            DaysRemaining := Round(Item.Inventory / DailyRate, 1)
        else
            DaysRemaining := 0;

        exit(
            '{"stock_duration":{' +
            '"item_no":"' + Item."No." + '",' +
            '"description":"' + EscapeJson(Item.Description) + '",' +
            '"current_inventory":' + Format(Item.Inventory, 0, '<Precision,2><Standard Format,9>') + ',' +
            '"predicted_daily_sales":' + Format(DailyRate, 0, '<Precision,2><Standard Format,9>') + ',' +
            '"estimated_days_remaining":' + Format(DaysRemaining, 0, '<Precision,1><Standard Format,9>') +
            '}}'
        );
    end;

    local procedure CallLatePaymentPrediction(UserMessage: Text; CustomerParam: Text; ChatHistoryJson: Text; Setup: Record "AI Assistant Setup"): Text
    var
        Client: HttpClient;
        RequestMsg: HttpRequestMessage;
        ResponseMsg: HttpResponseMessage;
        Content: HttpContent;
        Headers: HttpHeaders;
        Body: Text;
        ResponseText: Text;
        JsonObj: JsonObject;
        JsonArr: JsonArray;
        Token: JsonToken;
        PredToken: JsonToken;
        PredObj: JsonObject;
        ContextBuilder: TextBuilder;
        Customer: Record Customer;
        CustomerNo: Text;
        TrainingJson: Text;
        OpenInvoicesJson: Text;
        i: Integer;
        First: Boolean;
        DocNo: Text;
        CustNo: Text;
        Amount: Decimal;
        DaysUntilDue: Integer;
        WillBeLate: Boolean;
        Probability: Decimal;
        ExpectedDaysLate: Integer;
    begin
        CustomerNo := '';
        if CustomerParam <> '' then begin
            CustomerNo := ResolveCustomerNo(CustomerParam);
            // couldn't find a customer with that name, maybe it's a document number
            if not Customer.Get(CustomerNo) then begin
                TrainingJson := BuildLatePaymentTrainingJson();
                OpenInvoicesJson := BuildOpenInvoicesJson('', CustomerParam);
                // fall through to the HTTP call below
            end;
        end;

        if OpenInvoicesJson = '' then begin
            TrainingJson := BuildLatePaymentTrainingJson();
            OpenInvoicesJson := BuildOpenInvoicesJson(CustomerNo, '');
        end;

        Body := '{"training_data":' + TrainingJson + ',"invoices_to_predict":' + OpenInvoicesJson + '}';

        Content.WriteFrom(Body);
        Content.GetHeaders(Headers);
        Headers.Remove('Content-Type');
        Headers.Add('Content-Type', 'application/json');

        RequestMsg.Method := 'POST';
        RequestMsg.SetRequestUri(Setup."Backend URL" + '/predict-late-payment');
        RequestMsg.GetHeaders(Headers);
        Headers.Add('X-API-Key', Setup."API Key");
        Headers.Add('ngrok-skip-browser-warning', 'true'); // needed for ngrok tunnel; was originally hitting http://host.containerhelper.internal:8000 directly
        RequestMsg.Content := Content;

        if not Client.Send(RequestMsg, ResponseMsg) then
            Error('Failed to connect to AI backend.');

        ResponseMsg.Content.ReadAs(ResponseText);

        if not JsonObj.ReadFrom(ResponseText) then
            exit('Could not parse late payment response.');

        if JsonObj.Get('error', Token) then
            exit('Late payment prediction error: ' + Token.AsValue().AsText());

        if not JsonObj.Get('predictions', Token) then
            exit('No predictions returned.');

        JsonArr := Token.AsArray();

        ContextBuilder.Append('{"late_payment_predictions":[');
        First := true;
        for i := 0 to JsonArr.Count - 1 do begin
            JsonArr.Get(i, PredToken);
            PredObj := PredToken.AsObject();

            DocNo := '';
            CustNo := '';
            Amount := 0;
            DaysUntilDue := 0;
            WillBeLate := false;
            Probability := 0;
            ExpectedDaysLate := 0;

            if PredObj.Get('document_no', Token) then DocNo := Token.AsValue().AsText();
            if PredObj.Get('customer_no', Token) then CustNo := Token.AsValue().AsText();
            if PredObj.Get('invoice_amount', Token) then Amount := Token.AsValue().AsDecimal();
            if PredObj.Get('days_until_due', Token) then DaysUntilDue := Token.AsValue().AsInteger();
            if PredObj.Get('will_be_late', Token) then WillBeLate := Token.AsValue().AsBoolean();
            if PredObj.Get('probability', Token) then Probability := Token.AsValue().AsDecimal();
            if PredObj.Get('expected_days_late', Token) then ExpectedDaysLate := Token.AsValue().AsInteger();

            if not First then ContextBuilder.Append(',');
            ContextBuilder.Append('{"document_no":"');
            ContextBuilder.Append(EscapeJson(DocNo));
            ContextBuilder.Append('","customer_no":"');
            ContextBuilder.Append(EscapeJson(CustNo));
            ContextBuilder.Append('","invoice_amount":');
            ContextBuilder.Append(Format(Amount, 0, '<Precision,2><Standard Format,9>'));
            ContextBuilder.Append(',"days_until_due":');
            ContextBuilder.Append(Format(DaysUntilDue));
            ContextBuilder.Append(',"will_be_late":');
            if WillBeLate then ContextBuilder.Append('true') else ContextBuilder.Append('false');
            ContextBuilder.Append(',"probability":');
            ContextBuilder.Append(Format(Probability, 0, '<Precision,2><Standard Format,9>'));
            ContextBuilder.Append(',"expected_days_late":');
            ContextBuilder.Append(Format(ExpectedDaysLate));
            ContextBuilder.Append('}');
            First := false;
        end;
        ContextBuilder.Append(']}');

        exit(CallChat(UserMessage, ContextBuilder.ToText(), ChatHistoryJson, Setup));
    end;

    local procedure BuildLatePaymentTrainingJson(): Text
    var
        CLE: Record "Cust. Ledger Entry";
        Customer: Record Customer;
        JsonBuilder: TextBuilder;
        First: Boolean;
        WasLate: Boolean;
        DaysLate: Integer;
        PaymentTermsDays: Integer;
        PostingGroup: Text;
    begin
        CLE.Reset();
        CLE.SetRange("Document Type", CLE."Document Type"::Invoice);
        CLE.SetRange(Open, false);
        CLE.SetFilter("Closed at Date", '<>%1', 0D);
        CLE.SetFilter("Posting Date", '>=%1', CalcDate('<-2Y>', Today()));

        JsonBuilder.Append('[');
        First := true;
        if CLE.FindSet() then
            repeat
                if Customer.Get(CLE."Customer No.") then
                    PostingGroup := Customer."Customer Posting Group"
                else
                    PostingGroup := 'UNKNOWN';

                DaysLate := CLE."Closed at Date" - CLE."Due Date";
                WasLate := DaysLate > 0;
                if DaysLate < 0 then DaysLate := 0;

                PaymentTermsDays := CLE."Due Date" - CLE."Posting Date";
                if PaymentTermsDays < 0 then PaymentTermsDays := 0;

                if not First then JsonBuilder.Append(',');
                JsonBuilder.Append('{"customer_no":"');
                JsonBuilder.Append(EscapeJson(CLE."Customer No."));
                JsonBuilder.Append('","customer_posting_group":"');
                JsonBuilder.Append(EscapeJson(PostingGroup));
                JsonBuilder.Append('","invoice_amount":');
                JsonBuilder.Append(Format(Abs(CLE."Original Amount"), 0, '<Precision,2><Standard Format,9>'));
                JsonBuilder.Append(',"payment_terms_days":');
                JsonBuilder.Append(Format(PaymentTermsDays));
                JsonBuilder.Append(',"was_late":');
                if WasLate then JsonBuilder.Append('true') else JsonBuilder.Append('false');
                JsonBuilder.Append(',"days_late":');
                JsonBuilder.Append(Format(DaysLate));
                JsonBuilder.Append('}');
                First := false;
            until CLE.Next() = 0;
        JsonBuilder.Append(']');
        exit(JsonBuilder.ToText());
    end;

    local procedure BuildOpenInvoicesJson(CustomerNo: Text; DocumentNo: Text): Text
    var
        CLE: Record "Cust. Ledger Entry";
        Customer: Record Customer;
        JsonBuilder: TextBuilder;
        First: Boolean;
        PaymentTermsDays: Integer;
        DaysUntilDue: Integer;
        PostingGroup: Text;
    begin
        CLE.Reset();
        CLE.SetRange("Document Type", CLE."Document Type"::Invoice);
        CLE.SetRange(Open, true);
        if CustomerNo <> '' then
            CLE.SetRange("Customer No.", CustomerNo);
        if DocumentNo <> '' then
            CLE.SetRange("Document No.", DocumentNo);

        JsonBuilder.Append('[');
        First := true;
        if CLE.FindSet() then
            repeat
                if Customer.Get(CLE."Customer No.") then
                    PostingGroup := Customer."Customer Posting Group"
                else
                    PostingGroup := 'UNKNOWN';

                PaymentTermsDays := CLE."Due Date" - CLE."Posting Date";
                if PaymentTermsDays < 0 then PaymentTermsDays := 0;
                DaysUntilDue := CLE."Due Date" - Today();

                if not First then JsonBuilder.Append(',');
                JsonBuilder.Append('{"customer_no":"');
                JsonBuilder.Append(EscapeJson(CLE."Customer No."));
                JsonBuilder.Append('","document_no":"');
                JsonBuilder.Append(EscapeJson(CLE."Document No."));
                JsonBuilder.Append('","customer_posting_group":"');
                JsonBuilder.Append(EscapeJson(PostingGroup));
                JsonBuilder.Append('","invoice_amount":');
                JsonBuilder.Append(Format(Abs(CLE."Original Amount"), 0, '<Precision,2><Standard Format,9>'));
                JsonBuilder.Append(',"payment_terms_days":');
                JsonBuilder.Append(Format(PaymentTermsDays));
                JsonBuilder.Append(',"days_until_due":');
                JsonBuilder.Append(Format(DaysUntilDue));
                JsonBuilder.Append('}');
                First := false;
            until CLE.Next() = 0;
        JsonBuilder.Append(']');
        exit(JsonBuilder.ToText());
    end;

    local procedure ResolveCustomerNo(SearchTerm: Text): Text
    var
        Customer: Record Customer;
    begin
        SearchTerm := StripLeadingPrepositions(SearchTerm.Trim());

        if Customer.Get(SearchTerm) then
            exit(Customer."No.");

        Customer.Reset();
        Customer.SetFilter(Name, BuildWordFilter(SearchTerm));
        if Customer.FindFirst() then
            exit(Customer."No.");

        exit(SearchTerm);
    end;

    local procedure CountWorkingDays(FromDate: Date; ToDate: Date): Integer
    var
        CurrentDate: Date;
        Count: Integer;
    begin
        CurrentDate := FromDate;
        while CurrentDate <= ToDate do begin
            if Date2DWY(CurrentDate, 1) <= 5 then  // Mon=1 .. Fri=5, Sat=6, Sun=7
                Count += 1;
            CurrentDate := CurrentDate + 1;
        end;
        exit(Count);
    end;

    local procedure ValidateSetup(Setup: Record "AI Assistant Setup")
    begin
        if Setup."Backend URL" = '' then
            Error('Backend URL is not configured. Open AI Assistant Setup and enter the ngrok URL.');
        if Setup."API Key" = '' then
            Error('API Key is not configured. Open AI Assistant Setup and enter the API key.');
    end;
}
