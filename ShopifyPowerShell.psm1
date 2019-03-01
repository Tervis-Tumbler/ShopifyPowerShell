#Requires -Modules WebServicesPowerShellProxyBuilder

$ShopifyCredential = [System.Management.Automation.PSCredential]::Empty
$GetShopifyCredentialScriptBlock = {
    Import-Clixml -Path $env:USERPROFILE\ShopifyCredential.txt
}

function New-ShopifyCredential {
    Get-Credential -Message "Enter your Shopify API Key as the username and your API Password as the password" | 
    Export-Clixml -Path $env:USERPROFILE\ShopifyCredential.txt
}

function Get-ShopifyCredential {
    & $GetShopifyCredentialScriptBlock
}

function Set-GetShopifyCredentialScriptBlock {
    param (
        $ScriptBlock
    )
    $Script:GetShopifyCredentialScriptBlock = $ScriptBlock
}

function Invoke-ShopifyAPIFunction{
    [cmdletbinding()]
    param(
        $HttpMethod,
        $ShopName,
        $Resource,
        $Body
        )
    
    $Credential = Get-ShopifyCredential

    $URI = "https://$($Credential.UserName):$($Credential.GetNetworkCredential().Password)@$ShopName.myshopify.com/admin/$Resource"

    $Response = if ($Body) {
        Invoke-RestMethod -Method $HttpMethod -Credential $Credential -Uri $URI  -Body $Body
    } else {
        Invoke-RestMethod -Method $HttpMethod -Credential $Credential -Uri $URI
    }
    
    $Response
}

function Get-ShopifyInventoryItems{
    [cmdletbinding()]
    param(
    [Parameter(mandatory)]$ShopName,
    [Parameter(mandatory)]$ItemIDsSeparatedByCommas
    )

    $HttpMethod = "Get"
    $Resource = "inventory_items.json?ids=$ItemIDsSeparatedByCommas"

    Invoke-ShopifyAPIFunction -HttpMethod $HttpMethod -Resource $Resource -ShopName $ShopName
}

function Get-ShopifyShop{
    [cmdletbinding()]
    param(
    [Parameter(mandatory)]$ShopName
    )

    $HttpMethod = "Get"
    $Resource = "shop.json"

    Invoke-ShopifyAPIFunction -HttpMethod $HttpMethod -Resource $Resource -ShopName $ShopName

}