table 50101 "AI Data Quality Buffer"
{
    Caption = 'AI Data Quality Buffer';
    TableType = Temporary;
    DataClassification = SystemMetadata;

    fields
    {
        field(1; "No."; Code[20])
        {
            Caption = 'No.';
            DataClassification = SystemMetadata;
        }
        field(2; "Name"; Text[100])
        {
            Caption = 'Name';
            DataClassification = SystemMetadata;
        }
        field(3; "Record Count"; Integer)
        {
            Caption = 'Record Count';
            DataClassification = SystemMetadata;
        }
        field(4; "Meets Threshold"; Boolean)
        {
            Caption = 'Meets Threshold';
            DataClassification = SystemMetadata;
        }
        field(5; "Threshold"; Integer)
        {
            Caption = 'Min. Required';
            DataClassification = SystemMetadata;
        }
    }

    keys
    {
        key(PK; "No.")
        {
            Clustered = true;
        }
        key(Count; "Record Count")
        { }
    }
}
