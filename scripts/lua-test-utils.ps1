function ConvertTo-LuaLiteral($value) {
    if ($null -eq $value) { return 'nil' }
    if ($value -is [bool]) { return $(if ($value) { 'true' } else { 'false' }) }
    if ($value -is [string]) {
        return "'" + $value.Replace('\', '\\').Replace("'", "\'").Replace("`r", '\r').Replace("`n", '\n') + "'"
    }
    if ($value -is [System.Collections.IDictionary]) {
        $pairs = foreach ($key in $value.Keys) {
            "[" + (ConvertTo-LuaLiteral ([string]$key)) + "] = " + (ConvertTo-LuaLiteral $value[$key])
        }
        return '{' + ($pairs -join ', ') + '}'
    }
    if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
        $items = foreach ($item in $value) { ConvertTo-LuaLiteral $item }
        return '{' + ($items -join ', ') + '}'
    }
    if ($value -is [pscustomobject]) {
        $pairs = foreach ($property in $value.PSObject.Properties) {
            "[" + (ConvertTo-LuaLiteral $property.Name) + "] = " + (ConvertTo-LuaLiteral $property.Value)
        }
        return '{' + ($pairs -join ', ') + '}'
    }
    return ([System.Convert]::ToString($value, [System.Globalization.CultureInfo]::InvariantCulture))
}

function ConvertTo-LuaLongString([string]$value) {
    for ($level = 0; $level -le 16; $level++) {
        $equals = '=' * $level
        $close = "]$equals]"
        if (-not $value.Contains($close)) {
            return "[$equals[$value$close"
        }
    }
    throw 'Não foi possível criar um literal Lua longo sem colisão.'
}
