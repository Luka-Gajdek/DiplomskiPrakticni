table 50100 "AI Assistant Setup"
{
    Caption = 'AI Assistant Setup';
    DataClassification = CustomerContent;

    fields
    {
        field(1; "Primary Key"; Code[10])
        {
            Caption = 'Primary Key';
            DataClassification = SystemMetadata;
        }
        field(2; "Backend URL"; Text[250])
        {
            Caption = 'Backend URL';
            DataClassification = CustomerContent;
        }
        field(3; "API Key"; Text[250])
        {
            Caption = 'API Key';
            DataClassification = CustomerContent;
        }
        field(4; "Vacation Entitlement Days"; Integer)
        {
            Caption = 'Vacation Entitlement Days';
            DataClassification = CustomerContent;
            InitValue = 25;
        }
    }

    keys
    {
        key(PK; "Primary Key")
        {
            Clustered = true;
        }
    }

    procedure GetSetup(): Record "AI Assistant Setup"
    var
        Setup: Record "AI Assistant Setup";
    begin
        if not Setup.Get('') then begin
            Setup.Init();
            Setup."Primary Key" := '';
            Setup."Vacation Entitlement Days" := 25;
            Setup.Insert();
        end;
        exit(Setup);
    end;
}
