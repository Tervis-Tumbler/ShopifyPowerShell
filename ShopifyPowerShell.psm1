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

    $URI = "https://$($Credential.UserName):$($Credential.GetNetworkCredential().Password)@$ShopName.myshopify.com/admin/$Resource.json"

 #   $Response = if ($Body) {
 #       Invoke-RestMethod -Method $HttpMethod -Credential $Credential -Uri $URI  -Body $Body
 #   } else {
        Invoke-RestMethod -Credential $Credential -Uri $URI -Method $HttpMethod 
#    }
    
    $Response
}

function Get-ShopifyInventoryItems{
    [cmdletbinding()]
    param(
        [Parameter(mandatory)]$ShopName,
        [Parameter(mandatory)]$ItemIDsSeparatedByCommas
    )
    #$ItemIDsSeparatedByCommas needs to be refactored.

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
    $Resource = "shop"

    Invoke-ShopifyAPIFunction -HttpMethod $HttpMethod -Resource $Resource -ShopName $ShopName
}

function Get-ShopifyProducts{
    [cmdletbinding()]
    param(
        [parameter(mandatory)]$ShopName
    )

    $HttpMethod = "Get"
    $Resource = "products"

    Invoke-ShopifyAPIFunction -HttpMethod $HttpMethod -Resource $Resource -ShopName $ShopName
}

function New-ShopifyProduct{
    [cmdletbinding()]
    param(
        [parameter(mandatory)]$ShopName,
        [parameter(mandatory)]$Title,
        [parameter(mandatory)]$Description,
        [parameter(mandatory)]$EBSItemNumber,
        [parameter(mandatory)]$UPC,
        [parameter(mandatory)]$Price,
        $InventoryQuantity = 0
    )

    $HttpMethod = "Get"
    $Resource = "products"

    $Body = @"
{
    "product": {
        "title": "$Title",
        "body_html": "$Description",
        "variants: [
            {
                "price":"$Price",
                "sku":"$UPC",
                "id":"$EBSItemNumber"
                "inventory_quantity":$InventoryQuantity
            }
        ]
    }
}    
"@
}