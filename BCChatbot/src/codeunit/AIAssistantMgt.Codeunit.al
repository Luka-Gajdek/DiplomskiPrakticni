codeunit 50104 "AI Assistant Mgt."
{
    procedure SendMessage(UserMessage: Text; var ChatHistory: BigText): Text
    var
        Setup: Record "AI Assistant Setup";
        Context: Text;
        Reply: Text;
        Intent: Text;
        Parameter: Text;
        ForecastDays: Integer;
        SalesHistoryJson: Text;
    begin
        Setup := Setup.GetSetup();
        ValidateSetup(Setup);

        // Ask Llama3 to detect the user's intent
        DetectIntent(UserMessage, Setup, Intent, Parameter, ForecastDays);

        // Fallback: catch company rules questions Llama3 may have missed
        if (Intent = 'chat') and ContainsAny(UserMessage.ToLower(), 'rule,policy,expense,reimburse,compensat,dress code,conduct,working hours,vacation policy,safety,meeting,equipment,password,it policy') then
            Intent := 'company_rules';

        // Fallback: catch stock duration questions before image check
        if ContainsAny(UserMessage.ToLower(), 'how long,last,run out,stock last,days left,days of stock') then
            Intent := 'stock_duration';

        // Fallback: catch item image/photo requests (Llama3 often classifies these as item_info)
        if ContainsAny(UserMessage.ToLower(), 'picture,photo,image,show me a') then
            Intent := 'show_image';

        case Intent of
            'predict_sales':
                begin
                    if Parameter = '' then
                        Reply := 'Please specify an item number, e.g. "Predict sales for item 1000".'
                    else begin
                        Parameter := FindItemNo(Parameter);
                        SalesHistoryJson := BuildSalesHistoryJson(Parameter);
                        Reply := CallPredictSales(UserMessage, Parameter, SalesHistoryJson, ForecastDays, Setup);
                    end;
                end;
            'item_info':
                begin
                    Context := BuildItemContext(Parameter);
                    Reply := CallChat(UserMessage, Context, Setup);
                end;
            'vacation':
                begin
                    Context := BuildVacationContext(Parameter);
                    Reply := CallChat(UserMessage, Context, Setup);
                end;
            'customer':
                begin
                    Context := BuildCustomerContext(UserMessage);
                    Reply := CallChat(UserMessage, Context, Setup);
                end;
            'stock_duration':
                begin
                    if Parameter = '' then
                        Reply := 'Please specify an item, e.g. "How long will the stock of Tokyo Chair last?"'
                    else begin
                        Context := BuildStockDurationContext(Parameter, Setup);
                        Reply := CallChat(UserMessage, Context, Setup);
                    end;
                end;
            'show_image':
                begin
                    Reply := BuildItemImageResponse(UserMessage);
                end;
            'company_rules':
                begin
                    Context := GetCompanyRulesContext(Setup);
                    Reply := CallChat(UserMessage, Context, Setup);
                end;
            'late_payment':
                begin
                    Reply := CallLatePaymentPrediction(UserMessage, Parameter, Setup);
                end;
            else
                Reply := CallChat(UserMessage, '', Setup);
        end;

        exit(Reply);
    end;

    procedure TestConnection(Setup: Record "AI Assistant Setup")
    var
        Client: HttpClient;
        Response: HttpResponseMessage;
        Url: Text;
    begin
        Url := Setup."Backend URL" + '/health';
        Client.DefaultRequestHeaders().Add('X-API-Key', Setup."API Key");
        if Client.Get(Url, Response) then begin
            if Response.IsSuccessStatusCode() then
                Message('Connection successful! Backend is online.')
            else
                Error('Backend returned status %1.', Response.HttpStatusCode());
        end else
            Error('Could not reach the backend. Check the URL and that FastAPI + ngrok are running.');
    end;

    local procedure DetectIntent(UserMessage: Text; Setup: Record "AI Assistant Setup"; var Intent: Text; var Parameter: Text; var Days: Integer)
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

        Body := '{"message":' + JsonEscapeString(UserMessage) + '}';

        Content.WriteFrom(Body);
        Content.GetHeaders(Headers);
        Headers.Remove('Content-Type');
        Headers.Add('Content-Type', 'application/json');

        RequestMsg.Method := 'POST';
        RequestMsg.SetRequestUri(Setup."Backend URL" + '/detect-intent');
        RequestMsg.GetHeaders(Headers);
        Headers.Add('X-API-Key', Setup."API Key");
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
        end;
    end;

    local procedure CallChat(UserMessage: Text; Context: Text; Setup: Record "AI Assistant Setup"): Text
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
        Body := '{"message":' + JsonEscapeString(UserMessage) + ',"context":' + JsonEscapeString(Context) + '}';

        Content.WriteFrom(Body);
        Content.GetHeaders(Headers);
        Headers.Remove('Content-Type');
        Headers.Add('Content-Type', 'application/json');

        RequestMsg.Method := 'POST';
        RequestMsg.SetRequestUri(Setup."Backend URL" + '/chat');
        RequestMsg.GetHeaders(Headers);
        Headers.Add('X-API-Key', Setup."API Key");
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

    local procedure CallPredictSales(UserMessage: Text; ItemNo: Text; HistoryJson: Text; ForecastDays: Integer; Setup: Record "AI Assistant Setup"): Text
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

            exit(CallChat(UserMessage, Context, Setup));
        end;

        exit('Could not parse prediction response.');
    end;

    local procedure BuildVacationContext(SearchTerm: Text): Text
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
        ContextBuilder: TextBuilder;
        NameWords: List of [Text];
        FirstName: Text;
        LastName: Text;
        AbsenceEmployeeNo: Text;
        PeriodDays: Integer;
        FirstAbsence: Boolean;
    begin
        Setup := Setup.GetSetup();
        EntitlementDays := Setup."Vacation Entitlement Days";
        CurrentYear := Date2DMY(Today(), 3);
        StartOfYear := DMY2Date(1, 1, CurrentYear);
        EndOfYear := DMY2Date(31, 12, CurrentYear);

        SearchTerm := StripLeadingPrepositions(SearchTerm.Trim());

        if SearchTerm = '' then
            exit('{"error":"Please specify an employee name or ID."}');

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
                                exit('{"error":"No employee found matching \"' + SearchTerm + '\"."}');
                        end;
                    end;
                end else begin
                    Employee.SetFilter("First Name", '@*' + SearchTerm + '*');
                    if not Employee.FindFirst() then begin
                        Employee.Reset();
                        Employee.SetFilter("Last Name", '@*' + SearchTerm + '*');
                        if not Employee.FindFirst() then
                            exit('{"error":"No employee found matching \"' + SearchTerm + '\"."}');
                    end;
                end;
            end;
        end;

        // Employee Absence uses initials as Employee No. (e.g. "TD" for Terry Dodds)
        AbsenceEmployeeNo := CopyStr(Employee."First Name", 1, 1) + CopyStr(Employee."Last Name", 1, 1);

        // Build JSON with individual absence periods and calculate days from From Date / To Date
        ContextBuilder.Append('{"vacation":{"employee_no":"');
        ContextBuilder.Append(Employee."No.");
        ContextBuilder.Append('","employee_name":"');
        ContextBuilder.Append(Employee."First Name" + ' ' + Employee."Last Name");
        ContextBuilder.Append('","year":');
        ContextBuilder.Append(Format(CurrentYear));
        ContextBuilder.Append(',"entitlement_days":');
        ContextBuilder.Append(Format(EntitlementDays));
        ContextBuilder.Append(',"absences":[');

        AbsenceReg.Reset();
        AbsenceReg.SetRange("Employee No.", AbsenceEmployeeNo);
        AbsenceReg.SetFilter("From Date", '>=%1', StartOfYear);
        AbsenceReg.SetFilter("From Date", '<=%1', EndOfYear);
        FirstAbsence := true;
        if AbsenceReg.FindSet() then
            repeat
                if AbsenceReg."To Date" = 0D then
                    AbsenceReg."To Date" := AbsenceReg."From Date";
                PeriodDays := (AbsenceReg."To Date" - AbsenceReg."From Date") + 1;
                UsedDays += PeriodDays;

                if not FirstAbsence then
                    ContextBuilder.Append(',');
                ContextBuilder.Append('{"from":"');
                ContextBuilder.Append(Format(AbsenceReg."From Date", 0, '<Year4>-<Month,2>-<Day,2>'));
                ContextBuilder.Append('","to":"');
                ContextBuilder.Append(Format(AbsenceReg."To Date", 0, '<Year4>-<Month,2>-<Day,2>'));
                ContextBuilder.Append('","days":');
                ContextBuilder.Append(Format(PeriodDays));
                ContextBuilder.Append('}');
                FirstAbsence := false;
            until AbsenceReg.Next() = 0;

        RemainingDays := EntitlementDays - UsedDays;

        ContextBuilder.Append('],"used_days":');
        ContextBuilder.Append(Format(UsedDays, 0, '<Integer>'));
        ContextBuilder.Append(',"remaining_days":');
        ContextBuilder.Append(Format(RemainingDays, 0, '<Integer>'));
        ContextBuilder.Append('}}');

        exit(ContextBuilder.ToText());
    end;

    local procedure BuildSalesHistoryJson(ItemNo: Text): Text
    var
        ILE: Record "Item Ledger Entry";
        VE: Record "Value Entry";
        JsonBuilder: TextBuilder;
        First: Boolean;
        Qty: Decimal;
        SalesAmt: Decimal;
    begin
        ILE.Reset();
        ILE.SetRange("Item No.", ItemNo);
        ILE.SetRange("Entry Type", ILE."Entry Type"::Sale);

        JsonBuilder.Append('[');
        First := true;
        if ILE.FindSet() then
            repeat
                Qty := Abs(ILE.Quantity);
                // Get sales amount from Value Entry
                VE.Reset();
                VE.SetRange("Item Ledger Entry No.", ILE."Entry No.");
                VE.SetRange("Entry Type", VE."Entry Type"::"Direct Cost");
                SalesAmt := 0;
                if VE.FindFirst() then
                    SalesAmt := Abs(VE."Sales Amount (Actual)");

                if not First then
                    JsonBuilder.Append(',');
                JsonBuilder.Append('{"date":"');
                JsonBuilder.Append(Format(ILE."Posting Date", 0, '<Year4>-<Month,2>-<Day,2>'));
                JsonBuilder.Append('","quantity":');
                JsonBuilder.Append(Format(Qty, 0, '<Integer>'));
                JsonBuilder.Append(',"amount":');
                JsonBuilder.Append(Format(SalesAmt, 0, '<Precision,2><Standard Format,9>'));
                JsonBuilder.Append('}');
                First := false;
            until ILE.Next() = 0;
        JsonBuilder.Append(']');

        exit(JsonBuilder.ToText());
    end;

    local procedure BuildItemContext(UserMessage: Text): Text
    var
        Item: Record Item;
        JsonBuilder: TextBuilder;
        SearchTerm: Text;
        First: Boolean;
    begin
        SearchTerm := ExtractSearchTerm(UserMessage, 'item,stock,inventory');

        Item.SetRange(Blocked, false);
        Item.SetRange(Type, Item.Type::Inventory);
        if SearchTerm <> '' then
            Item.SetFilter(Description, BuildWordFilter(SearchTerm));
        Item.SetAutoCalcFields(Inventory);

        JsonBuilder.Append('{"items":[');
        First := true;
        if Item.FindSet() then
            repeat
                if not First then
                    JsonBuilder.Append(',');
                JsonBuilder.Append('{"no":"');
                JsonBuilder.Append(Item."No.");
                JsonBuilder.Append('","description":"');
                JsonBuilder.Append(EscapeJson(Item.Description));
                JsonBuilder.Append('","inventory":');
                JsonBuilder.Append(Format(Item.Inventory, 0, '<Precision,2><Standard Format,0>'));
                JsonBuilder.Append(',"unit_price":');
                JsonBuilder.Append(Format(Item."Unit Price", 0, '<Precision,2><Standard Format,0>'));
                JsonBuilder.Append('}');
                First := false;
            until Item.Next() = 0;
        JsonBuilder.Append(']}');

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

    local procedure BuildItemImageResponse(UserMessage: Text): Text
    var
        Item: Record Item;
        SearchTerm: Text;
        PictureBase64: Text;
    begin
        SearchTerm := ExtractSearchTerm(UserMessage, 'picture,photo,image');
        if SearchTerm = '' then
            SearchTerm := ExtractSearchTerm(UserMessage, 'item,product');
        SearchTerm := StripLeadingPrepositions(SearchTerm.Trim());

        if SearchTerm = '' then
            exit('Please specify which item you want to see, e.g. "Show me a picture of the Tokyo Chair".');

        Item.SetRange(Blocked, false);
        Item.SetFilter(Description, BuildWordFilter(SearchTerm));
        if not Item.FindFirst() then begin
            Item.Reset();
            Item.SetFilter("No.", '@*' + SearchTerm + '*');
            if not Item.FindFirst() then
                exit('Sorry, I couldn''t find an item matching "' + SearchTerm + '".');
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

    local procedure ExtractItemNo(UserMessage: Text): Text
    var
        Words: List of [Text];
        Word: Text;
        PrevWasItemKeyword: Boolean;
    begin
        Words := UserMessage.Split(' ');
        PrevWasItemKeyword := false;
        foreach Word in Words do begin
            Word := Word.Trim().ToUpper();
            if PrevWasItemKeyword and (Word <> '') and (Word <> 'ITEM') and (Word <> 'FOR') then
                exit(Word);
            if (Word = 'ITEM') or (Word = 'FOR') then
                PrevWasItemKeyword := true
            else
                PrevWasItemKeyword := false;
        end;
        exit('');
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
                // Strip trailing 's' for basic plural handling (chairs→chair, lamps→lamp)
                if Word.EndsWith('s') and (StrLen(Word) > 3) then
                    Word := CopyStr(Word, 1, StrLen(Word) - 1);
                if Filter <> '' then
                    Filter += '&';
                Filter += '@*' + Word + '*';
            end;
        end;
        if Filter = '' then
            Filter := '@*' + SearchTerm + '*';
        exit(Filter);
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
        if Item.FindFirst() then
            exit(Item."No.");

        // Return the original value — BuildSalesHistoryJson will handle the empty result
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
            Item.SetAutoCalcFields(Inventory);
            if not Item.Get(ItemParam) then
                exit('{"error":"Item not found: ' + ItemParam + '"}');
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

    local procedure CallLatePaymentPrediction(UserMessage: Text; CustomerParam: Text; Setup: Record "AI Assistant Setup"): Text
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
            // If we couldn't resolve to a known customer, treat it as a document number
            if not Customer.Get(CustomerNo) then begin
                TrainingJson := BuildLatePaymentTrainingJson();
                OpenInvoicesJson := BuildOpenInvoicesJson('', CustomerParam);
                // skip to call
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

        exit(CallChat(UserMessage, ContextBuilder.ToText(), Setup));
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

    local procedure ValidateSetup(Setup: Record "AI Assistant Setup")
    begin
        if Setup."Backend URL" = '' then
            Error('Backend URL is not configured. Open AI Assistant Setup and enter the ngrok URL.');
        if Setup."API Key" = '' then
            Error('API Key is not configured. Open AI Assistant Setup and enter the API key.');
    end;
}
