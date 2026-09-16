@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Interactive console tool: coloured status lines are intended.
        'PSAvoidUsingWriteHost',
        # Internal helper functions, not a public module: -WhatIf/-Confirm would add nothing.
        'PSUseShouldProcessForStateChangingFunctions',
        # Names such as Update-BcsaWorkers describe collections on purpose.
        'PSUseSingularNouns',
        # Best-effort cleanup/probing blocks intentionally ignore failures.
        'PSAvoidUsingEmptyCatchBlock'
    )
}
